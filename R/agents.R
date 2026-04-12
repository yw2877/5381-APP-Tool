# ---------- Agent layer — OpenAI-powered, real API calls only ----------

call_openai <- function(system_prompt, user_prompt, max_tokens = 800L) {
  if (!nzchar(openai_key())) {
    stop(paste(
      "OPENAI_API_KEY is not configured.",
      "Create a .env file in the project root with OPENAI_API_KEY=sk-...",
      "then restart the app."
    ))
  }

  resp <- httr2::request("https://api.openai.com/v1/chat/completions") |>
    httr2::req_headers(
      Authorization = paste("Bearer", openai_key()),
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
    httr2::req_timeout(30) |>
    httr2::req_error(is_error = function(resp) FALSE) |>
    httr2::req_perform()

  status <- httr2::resp_status(resp)
  if (status != 200L) {
    err_body <- tryCatch(httr2::resp_body_json(resp), error = function(e) list())
    err_msg  <- err_body$error$message %||% paste("HTTP", status)
    stop("OpenAI API error: ", err_msg)
  }

  parsed       <- httr2::resp_body_json(resp)
  content_text <- parsed$choices[[1]]$message$content
  content_text <- gsub("^```json\\s*", "", content_text)
  content_text <- gsub("^```\\s*",     "", content_text)
  content_text <- gsub("\\s*```$",     "", content_text)
  jsonlite::fromJSON(content_text, simplifyVector = FALSE)
}

# ---------- payload normalizer ----------
normalize_alert_payload <- function(payload) {
  list(
    symbol        = safe_chr(payload$symbol %||% payload$ticker %||% payload$asset,
                             default = "SPY"),
    event_type    = safe_chr(payload$event_type %||% payload$alert_name %||% payload$condition,
                             default = "watchlist_signal"),
    source        = safe_chr(payload$source %||% "tradingview",
                             default = "tradingview"),
    trigger_price = safe_num(payload$trigger_price %||% payload$price %||% payload$close,
                             default = NA_real_),
    message       = safe_chr(payload$message %||% payload$description,
                             default = "No message was provided in the webhook payload."),
    received_at   = safe_time(payload$timestamp %||% payload$time %||% Sys.time(),
                              default = Sys.time())
  )
}

# ========== Agent 1: Signal Triage Agent ==========

signal_triage_agent <- function(alert) {
  system_prompt <- paste(
    "You are Signal Triage Agent, a market risk classification specialist.",
    "Given a market alert, classify the incoming signal into one of these categories:",
    "trend_break, volatility_spike, momentum_reversal, liquidity_stress, watchlist_signal.",
    "Return JSON with exactly these keys:",
    "signal_type, severity_hint (low/medium/high), rationale (1-2 sentences),",
    "suggested_focus (array of 3 items to monitor next)."
  )

  user_prompt <- paste0(
    "Symbol: ",        alert$symbol,       "\n",
    "Event type: ",    alert$event_type,   "\n",
    "Alert message: ", alert$message,      "\n",
    "Trigger price: ", alert$trigger_price,"\n",
    "Time: ",          format_ts(alert$received_at)
  )

  result <- call_openai(system_prompt, user_prompt, max_tokens = 400L)
  result$agent          <- "Signal Triage Agent"
  result$suggested_focus <- as.list(result$suggested_focus %||% list())
  result
}

# Kept for reference; not called by the live pipeline.
signal_triage_fallback <- function(alert) {
  text_blob <- tolower(paste(alert$event_type, alert$message))

  if (grepl("atr|volatility|range", text_blob)) {
    signal_type <- "volatility_spike"; severity_hint <- "high"
    rationale <- "The alert language points to realized range expansion and a volatility regime shift."
    suggested_focus <- c("20d realized volatility", "1d/5d VaR", "liquidity gaps")
  } else if (grepl("death cross|cross|moving average", text_blob)) {
    signal_type <- "momentum_reversal"; severity_hint <- "medium"
    rationale <- "Moving-average crossover language suggests trend deterioration rather than a one-bar noise event."
    suggested_focus <- c("trend persistence", "follow-through volume", "drawdown acceleration")
  } else if (grepl("volume|liquidity|gap", text_blob)) {
    signal_type <- "liquidity_stress"; severity_hint <- "high"
    rationale <- "Volume and gap references usually coincide with weaker execution quality and wider tails."
    suggested_focus <- c("execution slippage", "spread sensitivity", "cross-asset spillover")
  } else if (grepl("bollinger|lower band|prior low|break", text_blob)) {
    signal_type <- "trend_break"; severity_hint <- "medium"
    rationale <- "The message reads like a support break or failed rebound, which fits a trend-break profile."
    suggested_focus <- c("support reclaim failure", "max drawdown", "next support zone")
  } else {
    signal_type <- "watchlist_signal"; severity_hint <- "medium"
    rationale <- "The payload does not map cleanly to a single regime, so the event is treated as a general watchlist signal."
    suggested_focus <- c("volatility", "drawdown", "correlation jump")
  }

  list(
    agent           = "Signal Triage Agent",
    signal_type     = signal_type,
    severity_hint   = severity_hint,
    rationale       = rationale,
    suggested_focus = as.list(suggested_focus)
  )
}

# ========== Agent 2: Risk Engine Agent ==========
# Uses Yahoo Finance data via compute_risk_metrics() — no OpenAI call needed.

risk_engine_agent <- function(alert, lookback = DEFAULT_LOOKBACK) {
  metrics    <- compute_risk_metrics(alert$symbol, lookback = lookback)
  alert_gap  <- if (is.finite(metrics$latest_price) && is.finite(alert$trigger_price)) {
    metrics$latest_price / alert$trigger_price - 1
  } else {
    NA_real_
  }
  metrics$alert_gap <- alert_gap
  metrics$agent     <- "Risk Engine Agent"
  metrics
}

# ========== Agent 3: Risk Memo Agent ==========

risk_memo_agent <- function(alert, triage, risk, knowledge) {
  terms_text <- paste(vapply(knowledge$terms, function(t) {
    paste0(t$term[[1]], ": ", t$definition[[1]])
  }, character(1)), collapse = "\n")

  cases_text <- paste(vapply(knowledge$cases, function(c) {
    paste0(c$case_name[[1]], " — ", c$summary[[1]])
  }, character(1)), collapse = "\n")

  playbook_text <- paste(knowledge$playbook, collapse = "\n")

  system_prompt <- paste(
    "You are Risk Memo Agent, a concise financial risk communicator.",
    "Write a short executive memo (3-5 sentences) that explains what happened,",
    "why risk increased, and what should be monitored next.",
    "Return JSON with keys: headline (short title), memo (the memo text),",
    "recommended_action (one sentence next step)."
  )

  user_prompt <- paste0(
    "Symbol: ",           alert$symbol,                                       "\n",
    "Signal type: ",      triage$signal_type,                                 "\n",
    "Severity: ",         triage$severity_hint,                               "\n",
    "Triage rationale: ", triage$rationale,                                   "\n",
    "Risk level: ",       risk$risk_level,                                    "\n",
    "Primary driver: ",   risk$primary_driver,                                "\n",
    "Regime score: ",     format_number(risk$regime_score,  accuracy = 0.01), "\n",
    "20d vol: ",          format_pct(risk$rolling_vol_20d),                   "\n",
    "1d VaR: ",           format_pct(risk$var_1d),                            "\n",
    "1d ES: ",            format_pct(risk$es_1d),                             "\n",
    "Max drawdown: ",     format_pct(risk$max_drawdown),                      "\n",
    "Correlation jump: ", format_number(risk$correlation_jump, accuracy = 0.01), "\n\n",
    "--- Knowledge context ---\n",
    "Risk terms:\n",              terms_text,    "\n\n",
    "Similar historical cases:\n", cases_text,   "\n\n",
    "Playbook guidance:\n",        playbook_text
  )

  result        <- call_openai(system_prompt, user_prompt, max_tokens = 600L)
  result$agent  <- "Risk Memo Agent"
  result
}

# Kept for reference; not called by the live pipeline.
risk_memo_fallback <- function(alert, triage, risk, knowledge) {
  headline <- glue::glue(
    "{alert$symbol}: {title_case(triage$signal_type)} flagged at {format_ts(alert$received_at)}"
  )

  term_ref <- knowledge$terms[[1]]$term[[1]] %||% "risk metrics"
  case_ref <- knowledge$cases[[1]]$case_name[[1]] %||% "prior stress episode"

  memo <- paste(
    glue::glue("{alert$symbol} is currently assessed as {toupper(risk$risk_level)} risk after a {title_case(triage$signal_type)} alert."),
    glue::glue("Primary driver: {title_case(risk$primary_driver)}. Regime score is {format_number(risk$regime_score, accuracy = 0.01)} with 20d realized volatility at {format_pct(risk$rolling_vol_20d)}."),
    glue::glue("Tail-risk snapshot: 1d VaR {format_pct(risk$var_1d)}, 1d ES {format_pct(risk$es_1d)}, max drawdown {format_pct(risk$max_drawdown)}."),
    glue::glue("Reference frame: pull {term_ref} into the explanation and compare this setup against {case_ref} before escalating."),
    "Recommended next step: verify whether the signal persists across the next 1 to 3 bars before treating it as a regime transition.",
    sep = "\n"
  )

  list(
    agent              = "Risk Memo Agent",
    headline           = headline,
    memo               = memo,
    recommended_action = "Verify whether the signal persists across the next 1 to 3 bars before treating it as a regime transition."
  )
}
