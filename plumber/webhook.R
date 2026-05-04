# Plumber webhook for TradingView alerts.
# Run with:
#   plumber::pr("plumber/webhook.R")$run(host = "0.0.0.0", port = 8000)
#
# In V3:
#   - source paths fixed to R/... (no more appv2/ prefix)
#   - /tv-alert returns 202 Accepted immediately and runs the pipeline
#     asynchronously via later::later() so TradingView doesn't time out
#   - /health reports DB / OpenAI / Yahoo / playbook readiness

source("R/paths.R")
options(appv2.app_root = find_app_root())
.env_path <- file.path(getOption("appv2.app_root"), ".env")
options(appv2.env_path = .env_path)
if (file.exists(.env_path) &&
    requireNamespace("dotenv", quietly = TRUE)) {
  dotenv::load_dot_env(.env_path)
}

source("R/config.R")
source("R/helpers.R")
source("R/schemas.R")
source("R/quality.R")
source("R/storage.R")
source("R/knowledge.R")
source("R/market_data.R")
source("R/llm.R")
source("R/agents.R")
source("R/pipeline.R")

ensure_runtime_state()

#* @apiTitle Market Stress Copilot Webhook
#* @apiVersion 3.0.0

validate_webhook_secret <- function(req) {
  if (!nzchar(TV_WEBHOOK_SECRET)) {
    return(TRUE)
  }
  provided <- req$HTTP_X_TV_SECRET %||% req$HTTP_X_WEBHOOK_SECRET %||% ""
  identical(safe_chr(provided, default = ""), TV_WEBHOOK_SECRET)
}

#* Health check — returns readiness of every external dependency
#* @get /health
function(res) {
  db_ok    <- file.exists(APP_DB_PATH)
  kb_ok    <- file.exists(PLAYBOOK_PATH)
  openai_ok <- nzchar(openai_key())
  yahoo    <- yahoo_health()

  ok <- db_ok && kb_ok
  if (!ok) res$status <- 503

  list(
    ok       = ok,
    app      = APP_TITLE,
    version  = "3.0.0",
    timestamp = format_ts(Sys.time()),
    db = list(ok = db_ok, path = APP_DB_PATH),
    knowledge_base = list(ok = kb_ok, path = PLAYBOOK_PATH),
    openai = list(ok = openai_ok, model = OPENAI_MODEL),
    yahoo  = yahoo,
    quality = list(
      threshold = QUALITY_THRESHOLD,
      max_iterations = MAX_LOOP_ITERATIONS
    )
  )
}

#* Lightweight metrics (last hour from agent_runs)
#* @get /metrics
function() {
  cutoff <- Sys.time() - 60 * 60
  runs <- tryCatch(fetch_agent_runs(since = cutoff, limit = 1000L),
                   error = function(e) data.frame())
  scores <- tryCatch(fetch_quality_scores(since = cutoff, limit = 1000L),
                     error = function(e) data.frame())

  if (!nrow(runs)) {
    return(list(window = "1h", n_runs = 0L, n_alerts = 0L))
  }

  list(
    window         = "1h",
    n_runs         = nrow(runs),
    n_alerts       = nrow(scores),
    avg_quality    = if (nrow(scores)) mean(scores$final_score, na.rm = TRUE) else NA_real_,
    pass_rate      = if (nrow(scores)) mean(scores$passed, na.rm = TRUE) else NA_real_,
    avg_iterations = if (nrow(scores)) mean(scores$iterations_used, na.rm = TRUE) else NA_real_,
    p50_latency_ms = stats::quantile(runs$latency_ms, 0.50, na.rm = TRUE),
    p95_latency_ms = stats::quantile(runs$latency_ms, 0.95, na.rm = TRUE),
    error_rate     = mean(!is.na(runs$error_class), na.rm = TRUE),
    cache_hit_rate = mean(runs$cache_hit, na.rm = TRUE)
  )
}

#* Receive TradingView alert payload (async pipeline)
#* @post /tv-alert
#* @serializer json list(auto_unbox = TRUE)
function(req, res) {
  if (!validate_webhook_secret(req)) {
    res$status <- 401
    return(list(ok = FALSE, error = "invalid webhook secret"))
  }

  payload <- tryCatch(
    jsonlite::fromJSON(req$postBody, simplifyVector = FALSE),
    error = function(e) {
      list(
        symbol     = "SPY",
        event_type = "malformed_payload",
        source     = "webhook",
        message    = paste("Webhook payload could not be parsed:", e$message)
      )
    }
  )

  # Persist alert immediately so the caller gets an ID even if the pipeline
  # is slow. Then schedule the agent pipeline to run async.
  alert <- normalize_alert_payload(payload)
  alert_id <- tryCatch(
    insert_alert_record(alert, raw_payload = payload),
    error = function(e) {
      res$status <- 500
      return(NULL)
    }
  )
  if (is.null(alert_id)) {
    return(list(ok = FALSE, error = "failed to persist alert"))
  }

  # Run pipeline async (later); webhook returns 202 immediately.
  if (requireNamespace("later", quietly = TRUE)) {
    later::later(function() {
      tryCatch({
        analysis <- run_agent_pipeline(alert,
                                       lookback = DEFAULT_LOOKBACK,
                                       alert_id = alert_id)
        save_analysis_record(alert_id, analysis,
          status = if (!is.null(analysis$partial_error)) "partial" else "ok")
        if (!is.null(analysis$quality)) {
          record_quality_score(alert_id, analysis$quality)
        }
      }, error = function(e) {
        message("async pipeline failed for alert_id=", alert_id, ": ",
                conditionMessage(e))
      })
    }, delay = 0)

    res$status <- 202
    return(list(
      ok = TRUE, accepted = TRUE,
      alert_id = alert_id,
      symbol = alert$symbol,
      message = "Alert accepted. Pipeline running asynchronously."
    ))
  }

  # No 'later' package → synchronous fallback (V2 behavior)
  result <- process_and_store_alert(payload, lookback = DEFAULT_LOOKBACK)
  list(
    ok          = TRUE,
    alert_id    = result$alert_id,
    symbol      = result$analysis$alert$symbol,
    risk_level  = result$analysis$risk$risk_level,
    signal_type = result$analysis$triage$signal_type
  )
}
