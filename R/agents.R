# ============================================================================
# R/agents.R — V3 agent layer
#
# Four agents:
#   1. signal_triage_agent  — LLM classifier (uses llm_call)
#   2. risk_engine_agent    — deterministic, no LLM (Yahoo Finance)
#   3. risk_memo_agent      — LLM, RAG-augmented, supports retry directives
#   4. critic_agent         — LLM, scores the memo + decides loop continues
#
# All LLM-backed agents go through llm_call() in R/llm.R, which provides
# retry, prompt-hash cache, schema validation, and telemetry.
#
# Fallback functions are kept and now wired into the degraded path.
# ============================================================================

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
    reference_type = safe_chr(
      payload$reference_type %||% payload$level_type %||% payload$threshold_type,
      default = ""
    ),
    reference_level = safe_num(
      payload$reference_level %||% payload$reference_price %||% payload$threshold_level,
      default = NA_real_
    ),
    message       = safe_chr(payload$message %||% payload$description,
                             default = "No message was provided in the webhook payload."),
    received_at   = safe_time(payload$timestamp %||% payload$time %||% Sys.time(),
                              default = Sys.time())
  )
}

# ============================================================================
# Agent 1: Signal Triage Agent
# ============================================================================

.triage_system_prompt <- function() {
  paste(
    "You are Signal Triage Agent, a market risk classification specialist.",
    "Given a market alert, classify the incoming signal into one of these",
    "categories: trend_break, volatility_spike, momentum_reversal,",
    "liquidity_stress, watchlist_signal.",
    "",
    "Return JSON with exactly these keys:",
    "  signal_type      — one of the 5 categories above",
    "  severity_hint    — one of low / medium / high",
    "  rationale        — 1-2 sentence explanation (30-600 chars)",
    "  suggested_focus  — array of 2-5 short strings (things to monitor next)",
    sep = "\n"
  )
}

.triage_user_prompt <- function(alert) {
  paste0(
    "Symbol: ",        alert$symbol,       "\n",
    "Event type: ",    alert$event_type,   "\n",
    "Alert message: ", alert$message,      "\n",
    "Trigger price: ", alert$trigger_price,"\n",
    "Time: ",          format_ts(alert$received_at)
  )
}

signal_triage_agent <- function(alert, alert_id = NULL) {
  result <- llm_call(
    system_prompt = .triage_system_prompt(),
    user_prompt   = .triage_user_prompt(alert),
    schema        = TRIAGE_SCHEMA,
    agent_name    = "triage",
    alert_id      = alert_id,
    iteration     = 1L,
    max_tokens    = 400L,
    cache         = TRUE
  )

  if (isTRUE(result$degraded)) {
    fb <- signal_triage_fallback(alert)
    fb$degraded       <- TRUE
    fb$degraded_error <- result$message
    return(fb)
  }

  result$agent           <- "Signal Triage Agent"
  result$suggested_focus <- as.list(result$suggested_focus %||% list())
  result$degraded        <- FALSE
  result
}

signal_triage_fallback <- function(alert) {
  text_blob <- tolower(paste(alert$event_type, alert$message))

  if (grepl("atr|volatility|range", text_blob)) {
    signal_type <- "volatility_spike"; severity_hint <- "high"
    rationale <- "Alert language points to realized range expansion and a volatility regime shift."
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

# ============================================================================
# Agent 2: Risk Engine Agent  (deterministic, Tool Calling)
# ============================================================================

risk_engine_agent <- function(alert, lookback = DEFAULT_LOOKBACK,
                              alert_id = NULL) {
  started <- Sys.time()
  metrics <- compute_risk_metrics(alert$symbol, lookback = lookback)
  alert_gap  <- if (is.finite(metrics$latest_price) && is.finite(alert$trigger_price)) {
    metrics$latest_price / alert$trigger_price - 1
  } else {
    NA_real_
  }
  metrics$alert_gap <- alert_gap

  # Apply deterministic guardrails (clip out-of-range Yahoo numbers)
  metrics <- clip_risk_metrics(metrics)
  metrics$completeness <- risk_metrics_completeness(metrics)

  metrics$agent <- "Risk Engine Agent"
  finished <- Sys.time()

  # Telemetry: record this as a "synthetic" agent run with no LLM call.
  record_agent_run(
    alert_id = alert_id, agent_name = "risk_engine", iteration = 1L,
    started_at = started, finished_at = finished,
    latency_ms = as.integer(difftime(finished, started, units = "secs") * 1000),
    n_retries = 0L, cache_hit = FALSE,
    validation_passed = !isTRUE(metrics$has_guardrail_flags),
    model = "deterministic"
  )
  metrics
}

# ============================================================================
# Agent 3: Risk Memo Agent  (LLM, RAG-augmented, retry-aware)
# ============================================================================

.memo_system_prompt <- function() {
  paste(
    "You are Risk Memo Agent, a concise financial risk communicator writing",
    "for an institutional trading desk.",
    "",
    "Write a short executive memo (3-5 sentences, 100-1500 chars) that:",
    "  1. states what happened in plain English,",
    "  2. cites at least one concrete metric from the structured risk block",
    "     (vol, VaR, drawdown, regime score, etc.),",
    "  3. explains why risk increased, and",
    "  4. ends with a specific, actionable next step.",
    "",
    "Avoid hype words ('crash', 'panic'), unfounded certainty",
    "('will definitely'), and hedging filler ('perhaps maybe possibly').",
    "",
    "Return JSON with exactly these keys:",
    "  headline           — 10-120 chars, specific (not generic)",
    "  memo               — 100-1500 chars body",
    "  recommended_action — 15-300 chars, one concrete next step",
    sep = "\n"
  )
}

.memo_user_prompt <- function(alert, triage, risk, knowledge,
                              improvement_directives = NULL,
                              previous_memo = NULL) {
  terms_text <- if (length(knowledge$terms) > 0) {
    paste(vapply(knowledge$terms, function(t) {
      paste0(safe_chr(t$term, "?"), ": ", safe_chr(t$definition, ""))
    }, character(1)), collapse = "\n")
  } else "(none)"

  cases_text <- if (length(knowledge$cases) > 0) {
    paste(vapply(knowledge$cases, function(c) {
      paste0(safe_chr(c$case_name, "?"), " — ", safe_chr(c$summary, ""))
    }, character(1)), collapse = "\n")
  } else "(none)"

  playbook_text <- if (length(knowledge$playbook) > 0) {
    paste(knowledge$playbook, collapse = "\n")
  } else "(none)"

  base <- paste0(
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

  # Retry path: previous draft + critic directives
  if (!is.null(improvement_directives) &&
      nzchar(safe_chr(improvement_directives, ""))) {
    prev_text <- if (!is.null(previous_memo)) {
      paste0(
        "\n\nYour previous draft:\n",
        "Headline: ", safe_chr(previous_memo$headline, ""), "\n",
        "Memo: ",     safe_chr(previous_memo$memo, ""),     "\n",
        "Action: ",   safe_chr(previous_memo$recommended_action, "")
      )
    } else ""

    base <- paste0(
      base,
      "\n\n--- IMPORTANT: this is a retry. Apply these critic directives EXACTLY: ---\n",
      improvement_directives,
      prev_text,
      "\n\nReturn a revised memo as JSON."
    )
  }

  base
}

risk_memo_agent <- function(alert, triage, risk, knowledge,
                            improvement_directives = NULL,
                            previous_memo = NULL,
                            iteration = 1L,
                            alert_id = NULL) {
  user_p <- .memo_user_prompt(alert, triage, risk, knowledge,
                              improvement_directives, previous_memo)
  cache_ok <- is.null(improvement_directives) ||
              !nzchar(safe_chr(improvement_directives, ""))

  result <- llm_call(
    system_prompt = .memo_system_prompt(),
    user_prompt   = user_p,
    schema        = MEMO_SCHEMA,
    agent_name    = if (iteration > 1L) "memo_retry" else "memo",
    alert_id      = alert_id,
    iteration     = as.integer(iteration),
    max_tokens    = 700L,
    cache         = cache_ok
  )

  if (isTRUE(result$degraded)) {
    fb <- risk_memo_fallback(alert, triage, risk, knowledge)
    fb$degraded       <- TRUE
    fb$degraded_error <- result$message
    return(fb)
  }

  result$agent    <- "Risk Memo Agent"
  result$degraded <- FALSE
  result
}

risk_memo_fallback <- function(alert, triage, risk, knowledge) {
  headline <- glue::glue(
    "{alert$symbol}: {title_case(triage$signal_type)} flagged at {format_ts(alert$received_at)}"
  )

  term_ref <- if (length(knowledge$terms) > 0) {
    safe_chr(knowledge$terms[[1]]$term, "risk metrics")
  } else "risk metrics"
  case_ref <- if (length(knowledge$cases) > 0) {
    safe_chr(knowledge$cases[[1]]$case_name, "prior stress episode")
  } else "prior stress episode"

  memo <- paste(
    glue::glue("{alert$symbol} is currently assessed as {toupper(safe_chr(risk$risk_level, 'monitor'))} risk after a {title_case(triage$signal_type)} alert."),
    glue::glue("Primary driver: {title_case(safe_chr(risk$primary_driver, 'baseline'))}. Regime score is {format_number(risk$regime_score, accuracy = 0.01)} with 20d realized volatility at {format_pct(risk$rolling_vol_20d)}."),
    glue::glue("Tail-risk snapshot: 1d VaR {format_pct(risk$var_1d)}, 1d ES {format_pct(risk$es_1d)}, max drawdown {format_pct(risk$max_drawdown)}."),
    glue::glue("Reference frame: pull {term_ref} into the explanation and compare this setup against {case_ref} before escalating."),
    "Recommended next step: verify whether the signal persists across the next 1 to 3 bars before treating it as a regime transition.",
    sep = "\n"
  )

  list(
    agent              = "Risk Memo Agent",
    headline           = as.character(headline),
    memo               = as.character(memo),
    recommended_action = "Verify whether the signal persists across the next 1 to 3 bars before treating it as a regime transition."
  )
}

# ============================================================================
# Agent 4: Critic Agent (NEW in V3)
# ============================================================================

.critic_system_prompt <- function() {
  paste(
    "You are Critic Agent, a senior risk officer reviewing a draft memo",
    "written by another agent for an institutional trading desk.",
    "",
    "Score the memo on five dimensions, each 0.0-1.0:",
    "1. clarity — readable in <30s? specific headline (not generic)?",
    "   direct sentences?",
    "2. completeness — covers what happened, why risk increased, what to",
    "   monitor? cites at least one concrete metric (vol, VaR, drawdown,",
    "   regime score)?",
    "3. actionability — recommended_action is a real next step a trader",
    "   could execute, not vague advice ('monitor closely')?",
    "4. factual_alignment — claims about risk level, primary driver, severity",
    "   match the structured risk metrics provided? Penalize hallucinated",
    "   numbers heavily.",
    "5. tone — analytical and neutral. No hype words ('crash','panic'),",
    "   no overconfident certainty ('will definitely'), no hedging filler",
    "   ('perhaps maybe possibly').",
    "",
    "Compute quality_score as a weighted average:",
    "  0.15*clarity + 0.25*completeness + 0.25*actionability +",
    "  0.30*factual_alignment + 0.05*tone",
    "",
    "passes = TRUE iff",
    "  quality_score >= 0.75 AND factual_alignment >= 0.70 AND",
    "  no dimension is below 0.40.",
    "",
    "If passes = FALSE, write improvement_directives as a SHORT IMPERATIVE",
    "checklist for the Memo Agent (e.g. '1. Cite the 20D vol of 38%",
    "explicitly. 2. Replace \"monitor closely\" with a specific stop level.",
    "3. Remove the word \"crash\".'). If passes = TRUE,",
    "improvement_directives must be exactly an empty string \"\".",
    "",
    "Return JSON with exactly these keys: quality_score (number 0-1),",
    "passes (boolean), dimension_scores (object with sub-keys clarity,",
    "completeness, actionability, factual_alignment, tone, all numbers 0-1),",
    "issues (array of short strings, max 5), improvement_directives (string).",
    sep = "\n"
  )
}

.critic_user_prompt <- function(alert, triage, risk, memo) {
  paste0(
    "--- Alert ---\n",
    "symbol: ",      alert$symbol,            "\n",
    "event_type: ",  alert$event_type,        "\n",
    "trigger_price: ", alert$trigger_price,   "\n",
    "message: ",     safe_chr(alert$message, ""), "\n\n",
    "--- Triage ---\n",
    "signal_type: ",   safe_chr(triage$signal_type,   "?"), "\n",
    "severity_hint: ", safe_chr(triage$severity_hint, "?"), "\n",
    "rationale: ",     safe_chr(triage$rationale,     ""), "\n\n",
    "--- Structured risk metrics (the source of truth) ---\n",
    format_risk_block_for_critic(risk), "\n\n",
    "--- Draft memo to score ---\n",
    "headline: ",            safe_chr(memo$headline, ""),           "\n",
    "memo: ",                safe_chr(memo$memo, ""),               "\n",
    "recommended_action: ",  safe_chr(memo$recommended_action, "")
  )
}

critic_agent <- function(alert, triage, risk, memo,
                         iteration = 1L, alert_id = NULL) {
  result <- llm_call(
    system_prompt = .critic_system_prompt(),
    user_prompt   = .critic_user_prompt(alert, triage, risk, memo),
    schema        = CRITIC_SCHEMA,
    agent_name    = "critic",
    alert_id      = alert_id,
    iteration     = as.integer(iteration),
    max_tokens    = 500L,
    cache         = TRUE
  )

  if (isTRUE(result$degraded)) {
    deg <- build_degraded_critique(memo, risk)
    deg$agent <- "Critic Agent"
    deg$degraded_error <- result$message
    return(deg)
  }

  # Coerce nested values (jsonlite returns lists for objects/arrays)
  ds <- result$dimension_scores %||% list()
  result$dimension_scores <- list(
    clarity           = safe_num(ds$clarity,           default = NA_real_),
    completeness      = safe_num(ds$completeness,      default = NA_real_),
    actionability     = safe_num(ds$actionability,     default = NA_real_),
    factual_alignment = safe_num(ds$factual_alignment, default = NA_real_),
    tone              = safe_num(ds$tone,              default = NA_real_)
  )
  result$quality_score <- safe_num(result$quality_score, default = NA_real_)
  result$passes        <- isTRUE(result$passes) ||
                          identical(result$passes, "true") ||
                          identical(result$passes, TRUE)
  result$issues        <- as.list(result$issues %||% list())
  result$improvement_directives <- safe_chr(result$improvement_directives, "")
  result$agent         <- "Critic Agent"
  result$degraded      <- FALSE
  result
}
