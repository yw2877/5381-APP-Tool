normalize_alert_payload <- function(payload) {
  list(
    symbol = safe_chr(
      payload$symbol %||% payload$ticker %||% payload$asset,
      default = "SPY"
    ),
    event_type = safe_chr(
      payload$event_type %||% payload$alert_name %||% payload$condition,
      default = "watchlist_signal"
    ),
    source = safe_chr(payload$source %||% "tradingview", default = "tradingview"),
    trigger_price = safe_num(
      payload$trigger_price %||% payload$price %||% payload$close,
      default = NA_real_
    ),
    message = safe_chr(
      payload$message %||% payload$description,
      default = "No message was provided in the webhook payload."
    ),
    received_at = safe_time(
      payload$timestamp %||% payload$time %||% Sys.time(),
      default = Sys.time()
    )
  )
}

signal_triage_agent <- function(alert) {
  text_blob <- tolower(paste(alert$event_type, alert$message))

  if (grepl("atr|volatility|range", text_blob)) {
    signal_type <- "volatility_spike"
    severity_hint <- "high"
    rationale <- "The alert language points to realized range expansion and a volatility regime shift."
    suggested_focus <- c("20d realized volatility", "1d/5d VaR", "liquidity gaps")
  } else if (grepl("death cross|cross|moving average", text_blob)) {
    signal_type <- "momentum_reversal"
    severity_hint <- "medium"
    rationale <- "Moving-average crossover language suggests trend deterioration rather than a one-bar noise event."
    suggested_focus <- c("trend persistence", "follow-through volume", "drawdown acceleration")
  } else if (grepl("volume|liquidity|gap", text_blob)) {
    signal_type <- "liquidity_stress"
    severity_hint <- "high"
    rationale <- "Volume and gap references usually coincide with weaker execution quality and wider tails."
    suggested_focus <- c("execution slippage", "spread sensitivity", "cross-asset spillover")
  } else if (grepl("bollinger|lower band|prior low|break", text_blob)) {
    signal_type <- "trend_break"
    severity_hint <- "medium"
    rationale <- "The message reads like a support break or failed rebound, which fits a trend-break profile."
    suggested_focus <- c("support reclaim failure", "max drawdown", "next support zone")
  } else {
    signal_type <- "watchlist_signal"
    severity_hint <- "medium"
    rationale <- "The payload does not map cleanly to a single regime, so the event is treated as a general watchlist signal."
    suggested_focus <- c("volatility", "drawdown", "correlation jump")
  }

  list(
    agent = "Signal Triage Agent",
    signal_type = signal_type,
    severity_hint = severity_hint,
    rationale = rationale,
    suggested_focus = as.list(suggested_focus)
  )
}

risk_engine_agent <- function(alert, lookback = DEFAULT_LOOKBACK) {
  metrics <- compute_risk_metrics(alert$symbol, lookback = lookback)

  alert_gap <- if (is.finite(metrics$latest_price) && is.finite(alert$trigger_price)) {
    metrics$latest_price / alert$trigger_price - 1
  } else {
    NA_real_
  }

  metrics$alert_gap <- alert_gap
  metrics$agent <- "Risk Engine Agent"
  metrics
}

risk_memo_agent <- function(alert, triage, risk, knowledge) {
  headline <- glue::glue(
    "{alert$symbol}: {title_case(triage$signal_type)} flagged at {format_ts(alert$received_at)}"
  )

  term_ref <- knowledge$terms[[1]]$term[[1]] %||% "risk metrics"
  case_ref <- knowledge$cases[[1]]$case_name[[1]] %||% "prior stress episode"

  memo <- paste(
    glue::glue(
      "{alert$symbol} is currently assessed as {toupper(risk$risk_level)} risk after a {title_case(triage$signal_type)} alert."
    ),
    glue::glue(
      "Primary driver: {title_case(risk$primary_driver)}. Regime score is {format_number(risk$regime_score, accuracy = 0.01)} with 20d realized volatility at {format_pct(risk$rolling_vol_20d)}."
    ),
    glue::glue(
      "Tail-risk snapshot: 1d VaR {format_pct(risk$var_1d)}, 1d ES {format_pct(risk$es_1d)}, max drawdown {format_pct(risk$max_drawdown)}."
    ),
    glue::glue(
      "Reference frame: pull {term_ref} into the explanation and compare this setup against {case_ref} before escalating."
    ),
    "Recommended next step: verify whether the signal persists across the next 1 to 3 bars before treating it as a regime transition.",
    sep = "\n"
  )

  list(
    agent = "Risk Memo Agent",
    headline = headline,
    memo = memo
  )
}
