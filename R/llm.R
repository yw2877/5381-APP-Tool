# ============================================================================
# R/llm.R — LLM gateway
#
# Single entry point for all OpenAI calls. Wraps call_openai() with:
#   - exponential backoff retry on transient errors (429, 5xx, timeout)
#   - in-memory prompt-hash cache (default 30 min TTL, configurable)
#   - JSON schema validation post-parse, with one schema-repair retry
#   - per-call telemetry written to agent_runs table
#   - graceful fallback path: returns list(degraded = TRUE, error = ...)
#     so callers never crash on transient OpenAI outages
#
# Public API:
#   llm_call(system_prompt, user_prompt, schema = NULL, agent_name,
#            alert_id = NULL, iteration = 1L, max_tokens = 600L,
#            cache = TRUE)
#     → returns parsed JSON list, or list(degraded = TRUE, error = msg)
#
#   llm_clear_cache()        # for tests + manual reset
#   llm_cache_stats()        # how many entries / hit rate
# ============================================================================

# ---------- prompt-hash cache (in-memory, per process) ----------
.llm_cache <- new.env(parent = emptyenv())
.llm_cache$entries <- list()  # key → list(value, expires_at)
.llm_cache$hits    <- 0L
.llm_cache$misses  <- 0L

.llm_cache_key <- function(system_prompt, user_prompt, model) {
  digest::digest(paste0(model, "|", system_prompt, "|", user_prompt),
                 algo = "sha1")
}

.llm_cache_get <- function(key) {
  e <- .llm_cache$entries[[key]]
  if (is.null(e)) return(NULL)
  if (e$expires_at < Sys.time()) {
    .llm_cache$entries[[key]] <- NULL
    return(NULL)
  }
  e$value
}

.llm_cache_set <- function(key, value) {
  .llm_cache$entries[[key]] <- list(
    value = value,
    expires_at = Sys.time() + LLM_CACHE_TTL_MIN * 60
  )
}

llm_clear_cache <- function() {
  .llm_cache$entries <- list()
  .llm_cache$hits    <- 0L
  .llm_cache$misses  <- 0L
  invisible(TRUE)
}

llm_cache_stats <- function() {
  total <- .llm_cache$hits + .llm_cache$misses
  list(
    entries = length(.llm_cache$entries),
    hits    = .llm_cache$hits,
    misses  = .llm_cache$misses,
    hit_rate = if (total > 0) .llm_cache$hits / total else NA_real_
  )
}

# ---------- one raw OpenAI call (no retry, returns httr2 response) ----------
.llm_request <- function(system_prompt, user_prompt, max_tokens) {
  if (!nzchar(openai_key())) {
    err <- structure(
      class = c("llm_no_key", "error", "condition"),
      list(message = "OPENAI_API_KEY not configured", call = sys.call())
    )
    stop(err)
  }

  httr2::request("https://api.openai.com/v1/chat/completions") |>
    httr2::req_headers(
      Authorization  = paste("Bearer", openai_key()),
      `Content-Type` = "application/json"
    ) |>
    httr2::req_body_json(list(
      model    = OPENAI_MODEL,
      messages = list(
        list(role = "system", content = system_prompt),
        list(role = "user",   content = user_prompt)
      ),
      temperature     = 0.4,
      max_tokens      = max_tokens,
      response_format = list(type = "json_object")
    )) |>
    httr2::req_timeout(LLM_TIMEOUT_SECONDS) |>
    httr2::req_error(is_error = function(resp) FALSE) |>
    httr2::req_perform()
}

# ---------- parse OpenAI response ----------
# Returns list(content_text, prompt_tokens, completion_tokens) or stop()s.
.llm_parse_response <- function(resp) {
  status <- httr2::resp_status(resp)

  # Transient errors → retryable
  if (status %in% c(429L, 500L, 502L, 503L, 504L)) {
    err_body <- tryCatch(httr2::resp_body_json(resp), error = function(e) list())
    err_msg  <- err_body$error$message %||% paste("HTTP", status)
    stop(structure(
      class = c("llm_transient", "error", "condition"),
      list(message = sprintf("OpenAI %d: %s", status, err_msg),
           call = sys.call(), status = status)
    ))
  }

  if (status != 200L) {
    err_body <- tryCatch(httr2::resp_body_json(resp), error = function(e) list())
    err_msg  <- err_body$error$message %||% paste("HTTP", status)
    stop(structure(
      class = c("llm_fatal", "error", "condition"),
      list(message = sprintf("OpenAI %d: %s", status, err_msg),
           call = sys.call(), status = status)
    ))
  }

  parsed <- httr2::resp_body_json(resp)
  txt    <- parsed$choices[[1]]$message$content
  txt    <- gsub("^```json\\s*", "", txt)
  txt    <- gsub("^```\\s*",     "", txt)
  txt    <- gsub("\\s*```$",     "", txt)

  list(
    content_text      = txt,
    prompt_tokens     = parsed$usage$prompt_tokens     %||% NA_integer_,
    completion_tokens = parsed$usage$completion_tokens %||% NA_integer_
  )
}

# ---------- one full attempt: request + parse + JSON parse ----------
.llm_one_attempt <- function(system_prompt, user_prompt, max_tokens) {
  resp   <- .llm_request(system_prompt, user_prompt, max_tokens)
  parsed <- .llm_parse_response(resp)
  obj    <- tryCatch(
    jsonlite::fromJSON(parsed$content_text, simplifyVector = FALSE),
    error = function(e) {
      stop(structure(
        class = c("llm_bad_json", "error", "condition"),
        list(message = sprintf("Invalid JSON from model: %s",
                               conditionMessage(e)),
             call = sys.call(), raw = parsed$content_text)
      ))
    }
  )
  list(
    obj               = obj,
    prompt_tokens     = parsed$prompt_tokens,
    completion_tokens = parsed$completion_tokens
  )
}

# ---------- main public API ----------
llm_call <- function(system_prompt, user_prompt,
                     schema      = NULL,
                     agent_name  = "unknown",
                     alert_id    = NULL,
                     iteration   = 1L,
                     max_tokens  = 600L,
                     cache       = TRUE) {

  started_at <- Sys.time()
  prompt_hash <- .llm_cache_key(system_prompt, user_prompt, OPENAI_MODEL)

  # ---------- cache lookup ----------
  if (isTRUE(cache)) {
    cached <- .llm_cache_get(prompt_hash)
    if (!is.null(cached)) {
      .llm_cache$hits <- .llm_cache$hits + 1L
      finished <- Sys.time()
      record_agent_run(
        alert_id = alert_id, agent_name = agent_name, iteration = iteration,
        started_at = started_at, finished_at = finished,
        latency_ms = as.integer(difftime(finished, started_at, units = "secs") * 1000),
        prompt_tokens = NA_integer_, completion_tokens = NA_integer_,
        n_retries = 0L, cache_hit = TRUE,
        validation_passed = TRUE,
        prompt_hash = prompt_hash, model = OPENAI_MODEL
      )
      return(cached)
    }
  }
  .llm_cache$misses <- .llm_cache$misses + 1L

  # ---------- retry loop ----------
  total_retries <- 0L
  attempt_user_prompt <- user_prompt
  schema_repair_used <- FALSE

  for (attempt in 1:LLM_MAX_RETRIES) {
    res <- tryCatch(
      .llm_one_attempt(system_prompt, attempt_user_prompt, max_tokens),
      llm_transient = function(e) {
        list(error = "transient", message = conditionMessage(e))
      },
      llm_bad_json  = function(e) {
        list(error = "bad_json", message = conditionMessage(e))
      },
      llm_fatal     = function(e) {
        list(error = "fatal", message = conditionMessage(e))
      },
      llm_no_key    = function(e) {
        list(error = "no_key", message = conditionMessage(e))
      },
      error         = function(e) {
        list(error = "exception", message = conditionMessage(e))
      }
    )

    # Hard failures — give up immediately
    if (!is.null(res$error) && res$error %in% c("no_key", "fatal")) {
      finished <- Sys.time()
      record_agent_run(
        alert_id = alert_id, agent_name = agent_name, iteration = iteration,
        started_at = started_at, finished_at = finished,
        latency_ms = as.integer(difftime(finished, started_at, units = "secs") * 1000),
        n_retries = total_retries, cache_hit = FALSE,
        validation_passed = FALSE,
        error_class = res$error, error_message = res$message,
        prompt_hash = prompt_hash, model = OPENAI_MODEL
      )
      return(list(degraded = TRUE, error = res$error, message = res$message))
    }

    # Soft failures — retry with backoff
    if (!is.null(res$error)) {
      total_retries <- total_retries + 1L
      if (attempt < LLM_MAX_RETRIES) {
        wait_s <- min(2 ^ attempt + stats::runif(1, 0, 1), 20)
        Sys.sleep(wait_s)
        next
      }
      # Out of retries
      finished <- Sys.time()
      record_agent_run(
        alert_id = alert_id, agent_name = agent_name, iteration = iteration,
        started_at = started_at, finished_at = finished,
        latency_ms = as.integer(difftime(finished, started_at, units = "secs") * 1000),
        n_retries = total_retries, cache_hit = FALSE,
        validation_passed = FALSE,
        error_class = res$error, error_message = res$message,
        prompt_hash = prompt_hash, model = OPENAI_MODEL
      )
      return(list(degraded = TRUE, error = res$error, message = res$message))
    }

    # Got a parsed response → schema-validate
    obj <- res$obj
    validation <- if (!is.null(schema)) {
      validate_against_schema(obj, schema)
    } else {
      list(ok = TRUE, errors = character(0))
    }

    if (isTRUE(validation$ok)) {
      finished <- Sys.time()
      record_agent_run(
        alert_id = alert_id, agent_name = agent_name, iteration = iteration,
        started_at = started_at, finished_at = finished,
        latency_ms = as.integer(difftime(finished, started_at, units = "secs") * 1000),
        prompt_tokens = res$prompt_tokens,
        completion_tokens = res$completion_tokens,
        n_retries = total_retries, cache_hit = FALSE,
        validation_passed = TRUE,
        prompt_hash = prompt_hash, model = OPENAI_MODEL
      )
      if (isTRUE(cache)) .llm_cache_set(prompt_hash, obj)
      return(obj)
    }

    # Schema invalid — try one repair attempt
    if (!schema_repair_used) {
      schema_repair_used <- TRUE
      total_retries <- total_retries + 1L
      attempt_user_prompt <- paste0(
        user_prompt,
        "\n\n--- IMPORTANT: Your previous response failed validation ---\n",
        paste(validation$errors, collapse = "\n"),
        "\n\nReturn JSON matching exactly this schema:\n",
        describe_schema(schema)
      )
      next
    }

    # Already retried with repair — give up
    finished <- Sys.time()
    record_agent_run(
      alert_id = alert_id, agent_name = agent_name, iteration = iteration,
      started_at = started_at, finished_at = finished,
      latency_ms = as.integer(difftime(finished, started_at, units = "secs") * 1000),
      prompt_tokens = res$prompt_tokens,
      completion_tokens = res$completion_tokens,
      n_retries = total_retries, cache_hit = FALSE,
      validation_passed = FALSE,
      error_class = "schema_invalid",
      error_message = paste(validation$errors, collapse = "; "),
      prompt_hash = prompt_hash, model = OPENAI_MODEL
    )
    return(list(degraded = TRUE,
                error = "schema_invalid",
                message = paste(validation$errors, collapse = "; ")))
  }

  # Should not reach here
  list(degraded = TRUE, error = "unknown", message = "Reached end of retry loop")
}
