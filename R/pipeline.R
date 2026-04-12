run_agent_pipeline <- function(alert, lookback = DEFAULT_LOOKBACK) {
  triage <- signal_triage_agent(alert)
  risk <- risk_engine_agent(alert, lookback = lookback)
  knowledge <- retrieve_knowledge(
    signal_type = triage$signal_type,
    symbol = alert$symbol,
    risk_level = risk$risk_level
  )
  memo <- risk_memo_agent(
    alert = alert,
    triage = triage,
    risk = risk,
    knowledge = knowledge
  )

  list(
    alert = alert,
    triage = triage,
    risk = risk,
    knowledge = knowledge,
    memo = memo
  )
}

process_and_store_alert <- function(payload, lookback = DEFAULT_LOOKBACK) {
  alert <- normalize_alert_payload(payload)
  alert_id <- insert_alert_record(alert, raw_payload = payload)
  analysis <- run_agent_pipeline(alert, lookback = lookback)
  save_analysis_record(alert_id, analysis)

  list(
    alert_id = alert_id,
    analysis = analysis
  )
}

baseline_alert <- function(symbol) {
  latest_price <- compute_risk_metrics(symbol)$latest_price

  list(
    symbol = safe_chr(symbol, default = "SPY"),
    event_type = "baseline_check",
    source = "system",
    trigger_price = latest_price,
    reference_type = "latest_price",
    reference_level = latest_price,
    message = "No live TradingView webhook yet. Showing baseline risk snapshot for the selected asset.",
    received_at = Sys.time()
  )
}

build_simulated_levels <- function(symbol, lookback = DEFAULT_LOOKBACK) {
  prices <- get_price_history(symbol, lookback = lookback)
  closes <- stats::na.omit(prices$close)
  latest_price <- safe_num(utils::tail(closes, 1), default = NA_real_)

  trailing <- if (length(closes) > 1) utils::head(closes, -1) else closes
  trailing <- utils::tail(trailing, min(20L, length(trailing)))
  if (!length(trailing)) {
    trailing <- closes
  }

  bb_window <- utils::tail(closes, min(20L, length(closes)))
  bb_mean <- mean(bb_window, na.rm = TRUE)
  bb_sd <- stats::sd(bb_window, na.rm = TRUE)

  slow_window <- utils::tail(closes, min(50L, length(closes)))
  vol20 <- rolling_volatility(prices, window = min(20L, max(2L, nrow(prices))))

  list(
    latest_price = latest_price,
    support_level = safe_num(min(trailing, na.rm = TRUE), default = latest_price),
    resistance_level = safe_num(max(trailing, na.rm = TRUE), default = latest_price),
    lower_band = safe_num(
      if (is.finite(bb_sd)) bb_mean - 2 * bb_sd else bb_mean,
      default = latest_price
    ),
    slow_ma = safe_num(mean(slow_window, na.rm = TRUE), default = latest_price),
    atr_threshold = safe_num(latest_price * vol20 / sqrt(252), default = latest_price * 0.02)
  )
}

simulation_reference_for_event <- function(levels, event_type) {
  switch(
    safe_chr(event_type, default = "watchlist_signal"),
    break_prior_low = list(reference_type = "prior_low_support", reference_level = levels$support_level),
    support_break = list(reference_type = "support", reference_level = levels$support_level),
    resistance_break = list(reference_type = "resistance", reference_level = levels$resistance_level),
    bollinger_breakdown = list(reference_type = "lower_band", reference_level = levels$lower_band),
    death_cross_volume = list(reference_type = "slow_ma", reference_level = levels$slow_ma),
    atr_expansion = list(reference_type = "atr_threshold", reference_level = levels$atr_threshold),
    list(reference_type = "latest_price", reference_level = levels$latest_price)
  )
}

simulation_trigger_price <- function(levels, event_type, reference_level) {
  event_type <- safe_chr(event_type, default = "watchlist_signal")

  candidate <- switch(
    event_type,
    break_prior_low = reference_level * (1 - 0.004),
    support_break = reference_level * (1 - 0.006),
    resistance_break = reference_level * (1 + 0.006),
    bollinger_breakdown = min(levels$latest_price, reference_level * (1 - 0.003)),
    death_cross_volume = min(levels$latest_price, reference_level * (1 - 0.002)),
    atr_expansion = levels$latest_price,
    levels$latest_price
  )

  safe_num(candidate, default = levels$latest_price)
}

build_simulated_alert <- function(symbol, lookback = DEFAULT_LOOKBACK, event_type = "random") {
  chosen_event <- safe_chr(event_type, default = "random")
  if (!nzchar(chosen_event) || identical(chosen_event, "random")) {
    template <- SIMULATED_EVENT_LIBRARY[[sample.int(length(SIMULATED_EVENT_LIBRARY), 1)]]
  } else {
    matching_idx <- which(vapply(
      SIMULATED_EVENT_LIBRARY,
      function(item) identical(safe_chr(item$event_type, default = ""), chosen_event),
      logical(1)
    ))
    if (length(matching_idx)) {
      template <- SIMULATED_EVENT_LIBRARY[[matching_idx[[1]]]]
    } else {
      template <- SIMULATED_EVENT_LIBRARY[[sample.int(length(SIMULATED_EVENT_LIBRARY), 1)]]
    }
  }

  levels <- build_simulated_levels(symbol, lookback = lookback)
  reference <- simulation_reference_for_event(levels, template$event_type)
  trigger_price <- simulation_trigger_price(
    levels = levels,
    event_type = template$event_type,
    reference_level = reference$reference_level
  )

  list(
    symbol = safe_chr(symbol, default = "SPY"),
    event_type = template$event_type,
    source = "simulator",
    trigger_price = trigger_price,
    reference_type = safe_chr(reference$reference_type, default = ""),
    reference_level = safe_num(reference$reference_level, default = NA_real_),
    message = template$message,
    timestamp = format_ts(Sys.time())
  )
}
