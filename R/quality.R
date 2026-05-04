# ============================================================================
# Quality / guardrail layer — deterministic checks that run BEFORE the
# Critic agent. Catches the easy cases (NaN, out-of-range, missing fields)
# without burning an LLM call.
#
# Used by:
#   - R/agents.R: risk_engine_agent() clips Yahoo Finance outliers
#   - R/llm.R:    after JSON parse, calls validate_against_schema()
#   - R/server.R: the Quality Snapshot card surfaces flags to the user
# ============================================================================

# ----- Risk metric range guardrails -----
# Clips out-of-range numeric values to schema bounds and returns a
# stale_data flag if any clipping happened. NA is preserved (means data missing).
clip_risk_metrics <- function(metrics) {
  if (!is.list(metrics)) return(metrics)

  flags <- character(0)
  out   <- metrics

  for (key in names(RISK_METRICS_RANGES)) {
    rule <- RISK_METRICS_RANGES[[key]]
    val  <- out[[key]]
    if (is.null(val) || !is.finite(val)) next

    if (!is.null(rule$min) && val < rule$min) {
      flags <- c(flags, sprintf("%s clipped from %.4f to min %.2f",
                                key, val, rule$min))
      out[[key]] <- rule$min
    } else if (!is.null(rule$max) && val > rule$max) {
      flags <- c(flags, sprintf("%s clipped from %.4f to max %.2f",
                                key, val, rule$max))
      out[[key]] <- rule$max
    }
  }

  out$guardrail_flags <- flags
  out$has_guardrail_flags <- length(flags) > 0
  out
}

# ----- NaN / completeness checks for risk metrics -----
# Returns the proportion of expected metrics that are missing/NaN.
# Used by Critic prompt: high missingness lowers factual_alignment ceiling.
risk_metrics_completeness <- function(metrics) {
  expected <- c("rolling_vol_20d", "max_drawdown", "var_1d", "es_1d",
                "regime_score", "primary_driver", "risk_level", "latest_price")
  if (!is.list(metrics)) return(0)
  present <- vapply(expected, function(k) {
    val <- metrics[[k]]
    !is.null(val) &&
      ((is.numeric(val) && is.finite(val)) ||
       (is.character(val) && nzchar(val)))
  }, logical(1))
  mean(present)
}

# ----- Format risk metrics for Critic prompt -----
# Provides the structured-truth block the Critic uses to detect
# hallucinated numbers in the memo.
format_risk_block_for_critic <- function(risk) {
  if (!is.list(risk)) return("(no risk metrics available)")

  fmt_num <- function(x, fmt = "%.4f") {
    if (is.null(x) || !is.finite(safe_num(x, NA_real_))) return("NA")
    sprintf(fmt, safe_num(x))
  }
  fmt_pct <- function(x) {
    n <- safe_num(x, NA_real_)
    if (!is.finite(n)) return("NA")
    sprintf("%.2f%%", n * 100)
  }

  lines <- c(
    sprintf("symbol: %s",            safe_chr(risk$symbol, "?")),
    sprintf("risk_level: %s",        safe_chr(risk$risk_level, "?")),
    sprintf("primary_driver: %s",    safe_chr(risk$primary_driver, "?")),
    sprintf("latest_price: %s",      fmt_num(risk$latest_price, "%.4f")),
    sprintf("rolling_vol_20d: %s",   fmt_pct(risk$rolling_vol_20d)),
    sprintf("max_drawdown: %s",      fmt_pct(risk$max_drawdown)),
    sprintf("var_1d (95%%): %s",     fmt_pct(risk$var_1d)),
    sprintf("es_1d: %s",             fmt_pct(risk$es_1d)),
    sprintf("regime_score: %s",      fmt_num(risk$regime_score, "%.3f")),
    sprintf("correlation_jump: %s",  fmt_num(risk$correlation_jump, "%.3f")),
    sprintf("alert_gap: %s",         fmt_num(risk$alert_gap, "%.4f"))
  )

  if (length(risk$guardrail_flags) > 0) {
    lines <- c(lines, "guardrail_notes:",
               paste0("  - ", risk$guardrail_flags))
  }
  paste(lines, collapse = "\n")
}

# ----- Memo completeness signals (deterministic) -----
# Cheap pre-checks that supplement the Critic. Used by:
#   - R/llm.R: degraded fallback path uses these to construct a fake critique
#   - R/server.R: Quality Snapshot card shows them
memo_completeness_signals <- function(memo, risk) {
  txt <- safe_chr(memo$memo, "")
  if (!nzchar(txt)) {
    return(list(
      has_metric    = FALSE,
      has_action    = FALSE,
      has_driver    = FALSE,
      length_chars  = 0L,
      hype_words    = character(0)
    ))
  }

  lc <- tolower(txt)

  # Check whether any of the structured numbers was cited
  metric_patterns <- c("vol", "var", "drawdown", "regime", "correlation", "%")
  has_metric <- any(vapply(metric_patterns,
                           function(p) grepl(p, lc, fixed = TRUE),
                           logical(1)))

  driver <- tolower(safe_chr(risk$primary_driver, ""))
  has_driver <- nzchar(driver) && grepl(driver, lc, fixed = TRUE)

  has_action <- nchar(safe_chr(memo$recommended_action, "")) >= 15

  hype <- c("crash", "panic", "skyrocket", "explode", "doomed",
            "definitely", "certainly", "guaranteed",
            "perhaps maybe", "could possibly", "might possibly")
  hits <- hype[vapply(hype, function(w) grepl(w, lc, fixed = TRUE), logical(1))]

  list(
    has_metric    = has_metric,
    has_action    = has_action,
    has_driver    = has_driver,
    length_chars  = nchar(txt),
    hype_words    = hits
  )
}

# ----- Construct a deterministic critique for degraded mode -----
# When the Critic LLM is unreachable, build a best-effort score from
# memo_completeness_signals(). Marks degraded = TRUE so the UI can flag it.
build_degraded_critique <- function(memo, risk) {
  sig <- memo_completeness_signals(memo, risk)

  clarity        <- if (sig$length_chars >= 100 && sig$length_chars <= 1500) 0.7 else 0.4
  completeness   <- 0.3 + 0.3 * sig$has_metric + 0.2 * sig$has_driver
  actionability  <- if (sig$has_action) 0.7 else 0.3
  factual        <- 0.6  # cannot verify without LLM
  tone           <- if (length(sig$hype_words) == 0) 0.8 else 0.4

  score <- 0.15 * clarity + 0.25 * completeness +
           0.25 * actionability + 0.30 * factual + 0.05 * tone

  list(
    quality_score = round(score, 3),
    passes        = score >= 0.75,
    dimension_scores = list(
      clarity          = clarity,
      completeness     = completeness,
      actionability    = actionability,
      factual_alignment = factual,
      tone             = tone
    ),
    issues = c(
      if (!sig$has_metric)  "Memo did not cite a concrete metric.",
      if (!sig$has_action)  "Recommended action is too short or missing.",
      if (length(sig$hype_words) > 0)
        sprintf("Tone words flagged: %s", paste(sig$hype_words, collapse = ", "))
    ),
    improvement_directives = "",
    degraded = TRUE,
    degraded_reason = "Critic LLM unavailable — score computed deterministically."
  )
}
