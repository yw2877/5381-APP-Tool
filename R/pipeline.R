# ============================================================================
# R/pipeline.R — V3 agentic loop
#
# Orchestrates: Triage → Risk Engine → Memo → Critic → (optional re-Memo)
# The Critic decides whether the memo passes; if not, the loop regenerates
# the memo with critique feedback. Capped by MAX_LOOP_ITERATIONS.
# ============================================================================

run_agent_pipeline <- function(alert, lookback = DEFAULT_LOOKBACK,
                               alert_id       = NULL,
                               max_iterations = MAX_LOOP_ITERATIONS,
                               quality_threshold = QUALITY_THRESHOLD) {

  # 1. Triage
  triage <- signal_triage_agent(alert, alert_id = alert_id)

  # 2. Risk Engine (deterministic)
  risk <- risk_engine_agent(alert, lookback = lookback, alert_id = alert_id)

  # 3. Knowledge retrieval (RAG)
  knowledge <- retrieve_knowledge(
    signal_type = triage$signal_type,
    symbol      = alert$symbol,
    risk_level  = risk$risk_level
  )

  # 4. First memo
  iterations <- list()
  memo <- risk_memo_agent(
    alert = alert, triage = triage, risk = risk, knowledge = knowledge,
    iteration = 1L, alert_id = alert_id
  )

  # 5. First critique
  critique <- critic_agent(
    alert = alert, triage = triage, risk = risk, memo = memo,
    iteration = 1L, alert_id = alert_id
  )
  iterations[[1L]] <- list(
    iteration = 1L,
    memo      = memo,
    critique  = critique,
    t         = format_ts(Sys.time())
  )

  # 6. Loop while not passing
  iter <- 1L
  while (!isTRUE(critique$passes) && iter < max_iterations) {
    iter <- iter + 1L

    # Memo with directives
    memo <- risk_memo_agent(
      alert = alert, triage = triage, risk = risk, knowledge = knowledge,
      improvement_directives = critique$improvement_directives,
      previous_memo = memo,
      iteration = iter, alert_id = alert_id
    )

    # New critique
    critique <- critic_agent(
      alert = alert, triage = triage, risk = risk, memo = memo,
      iteration = iter, alert_id = alert_id
    )

    iterations[[iter]] <- list(
      iteration = iter,
      memo      = memo,
      critique  = critique,
      t         = format_ts(Sys.time())
    )
  }

  list(
    alert     = alert,
    triage    = triage,
    risk      = risk,
    knowledge = knowledge,
    memo      = memo,
    quality   = list(
      final_score        = safe_num(critique$quality_score, default = NA_real_),
      passed             = isTRUE(critique$passes),
      iterations_used    = iter,
      dimension_scores   = critique$dimension_scores,
      issues             = critique$issues,
      improvement_directives = critique$improvement_directives,
      iteration_history  = iterations,
      degraded           = isTRUE(critique$degraded) ||
                           isTRUE(memo$degraded) ||
                           isTRUE(triage$degraded)
    )
  )
}

# ----------------------------------------------------------------------------
# process_and_store_alert: end-to-end + persistence
# Wrapped in tryCatch so a mid-pipeline failure persists what we have.
# ----------------------------------------------------------------------------
process_and_store_alert <- function(payload, lookback = DEFAULT_LOOKBACK) {
  alert <- normalize_alert_payload(payload)
  alert_id <- insert_alert_record(alert, raw_payload = payload)

  analysis <- tryCatch(
    run_agent_pipeline(alert, lookback = lookback, alert_id = alert_id),
    error = function(e) {
      message("run_agent_pipeline failed: ", conditionMessage(e))
      list(
        alert     = alert,
        triage    = NULL,
        risk      = NULL,
        knowledge = NULL,
        memo      = NULL,
        quality   = NULL,
        partial_error = conditionMessage(e)
      )
    }
  )

  status <- if (!is.null(analysis$partial_error)) "partial" else "ok"

  # Save analysis (handles partial)
  tryCatch(
    save_analysis_record(alert_id, analysis, status = status),
    error = function(e) {
      message("save_analysis_record failed: ", conditionMessage(e))
    }
  )

  if (!is.null(analysis$quality)) {
    record_quality_score(alert_id, analysis$quality)
  }

  list(
    alert_id = alert_id,
    analysis = analysis,
    status   = status
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

demo_event_type_for_asset <- function(symbol) {
  switch(
    safe_chr(symbol, default = "SPY"),
    "BTCUSDT" = "atr_expansion",
    "ETHUSDT" = "support_break",
    "SPY"     = "support_break",
    "QQQ"     = "break_prior_low",
    "NVDA"    = "death_cross_volume",
    "support_break"
  )
}

record_demo_agent_run <- function(alert_id, agent_name, iteration = 1L, expr) {
  started <- Sys.time()
  value <- force(expr)
  finished <- Sys.time()
  record_agent_run(
    alert_id = alert_id,
    agent_name = agent_name,
    iteration = as.integer(iteration),
    started_at = started,
    finished_at = finished,
    latency_ms = as.integer(difftime(finished, started, units = "secs") * 1000),
    n_retries = 0L,
    cache_hit = FALSE,
    validation_passed = TRUE,
    model = "deterministic_demo"
  )
  value
}

run_demo_pipeline <- function(alert, lookback = DEFAULT_LOOKBACK, alert_id = NULL) {
  triage <- record_demo_agent_run(
    alert_id,
    "triage",
    expr = {
      out <- signal_triage_fallback(alert)
      out$agent <- "Signal Triage Agent"
      out$degraded <- FALSE
      out
    }
  )

  risk <- risk_engine_agent(alert, lookback = lookback, alert_id = alert_id)

  knowledge <- retrieve_knowledge(
    signal_type = triage$signal_type,
    symbol = alert$symbol,
    risk_level = risk$risk_level
  )

  memo <- record_demo_agent_run(
    alert_id,
    "memo",
    expr = {
      out <- risk_memo_fallback(alert, triage, risk, knowledge)
      out$degraded <- FALSE
      out
    }
  )

  critique <- record_demo_agent_run(
    alert_id,
    "critic",
    expr = build_degraded_critique(memo, risk)
  )

  list(
    alert = alert,
    triage = triage,
    risk = risk,
    knowledge = knowledge,
    memo = memo,
    quality = list(
      final_score = safe_num(critique$quality_score, default = NA_real_),
      passed = isTRUE(critique$passes),
      iterations_used = 1L,
      dimension_scores = critique$dimension_scores,
      issues = as.list(critique$issues %||% list()),
      improvement_directives = safe_chr(critique$improvement_directives, default = ""),
      iteration_history = list(list(
        iteration = 1L,
        memo = memo,
        critique = critique,
        t = format_ts(Sys.time())
      )),
      degraded = FALSE
    )
  )
}

preload_demo_content <- function(mode = PRELOAD_DEMO_MODE,
                                 assets = NULL,
                                 lookback = DEFAULT_LOOKBACK,
                                 force = FALSE) {
  mode <- tolower(trimws(safe_chr(mode, default = "off")))
  if (identical(mode, "off")) {
    return(invisible(list(ok = TRUE, skipped = "mode_off")))
  }

  if (!isTRUE(force) && count_alert_history() > 0L) {
    return(invisible(list(ok = TRUE, skipped = "alerts_present")))
  }

  if (is.null(assets) || !length(assets)) {
    assets <- if (nzchar(PRELOAD_DEMO_ASSETS)) {
      trimws(strsplit(PRELOAD_DEMO_ASSETS, ",", fixed = TRUE)[[1]])
    } else {
      APP_ASSETS$label
    }
  }
  assets <- unique(assets[nzchar(assets)])

  if (identical(mode, "auto")) {
    mode <- if (nzchar(openai_key())) "full" else "deterministic"
  }

  results <- vector("list", length(assets))
  names(results) <- assets

  for (i in seq_along(assets)) {
    symbol <- assets[[i]]
    payload <- build_simulated_alert(
      symbol,
      lookback = lookback,
      event_type = demo_event_type_for_asset(symbol)
    )

    results[[i]] <- tryCatch({
      if (identical(mode, "full")) {
        process_and_store_alert(payload, lookback = lookback)
      } else {
        alert <- normalize_alert_payload(payload)
        alert_id <- insert_alert_record(alert, raw_payload = payload)
        analysis <- run_demo_pipeline(alert, lookback = lookback, alert_id = alert_id)
        save_analysis_record(alert_id, analysis, status = "ok")
        record_quality_score(alert_id, analysis$quality)
        list(alert_id = alert_id, analysis = analysis, status = "ok")
      }
    }, error = function(e) {
      list(
        alert_id = NA_integer_,
        status = "error",
        error = conditionMessage(e),
        symbol = symbol
      )
    })
  }

  invisible(list(ok = TRUE, mode = mode, assets = assets, results = results))
}
