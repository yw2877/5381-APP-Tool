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
    message = "No live TradingView webhook yet. Showing baseline risk snapshot for the selected asset.",
    received_at = Sys.time()
  )
}

build_simulated_alert <- function(symbol) {
  template <- SIMULATED_EVENT_LIBRARY[[sample.int(length(SIMULATED_EVENT_LIBRARY), 1)]]
  price <- compute_risk_metrics(symbol)$latest_price

  list(
    symbol = safe_chr(symbol, default = "SPY"),
    event_type = template$event_type,
    source = "simulator",
    trigger_price = price,
    message = template$message,
    timestamp = format_ts(Sys.time())
  )
}
