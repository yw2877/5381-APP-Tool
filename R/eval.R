# ============================================================================
# R/eval.R — V3 evaluation harness
#
# Used to produce the "Before / After" evidence the slide deck needs:
#   - Run the same alert library through V2 (single-pass) and V3 (with
#     Critic loop).
#   - Compute aggregate quality + latency stats.
#   - Compare side-by-side.
#
# Public API:
#   build_eval_alert_set()        — deterministic mix of asset × event_type
#   run_eval_set(alerts, label)   — run pipeline N times, return data.frame
#   v2_compat_pipeline(alert)     — single-pass pipeline (no Critic loop)
#   compare_eval_runs(v2, v3)     — joined comparison with deltas
#   write_eval_csvs(...)          — persist for slide deck
# ============================================================================

build_eval_alert_set <- function(n_per_event = 2L,
                                 lookback = DEFAULT_LOOKBACK,
                                 seed = 42L) {
  set.seed(seed)
  symbols <- APP_ASSETS$label
  events <- vapply(SIMULATED_EVENT_LIBRARY,
                   function(item) safe_chr(item$event_type, "watchlist_signal"),
                   character(1))

  alerts <- list()
  i <- 0L
  for (sym in symbols) {
    for (ev in events) {
      for (rep in seq_len(n_per_event)) {
        i <- i + 1L
        alerts[[i]] <- tryCatch({
          payload <- build_simulated_alert(sym, lookback = lookback,
                                           event_type = ev)
          a <- normalize_alert_payload(payload)
          a$eval_id <- sprintf("%s__%s__%02d", sym, ev, rep)
          a
        }, error = function(e) NULL)
      }
    }
  }
  Filter(Negate(is.null), alerts)
}

# ----------------------------------------------------------------------------
# v2_compat_pipeline — re-creates the V2 single-pass behavior (no critic
# loop) so we can score "Before / After" cleanly. Risk Engine is shared.
# ----------------------------------------------------------------------------
v2_compat_pipeline <- function(alert, lookback = DEFAULT_LOOKBACK) {
  triage    <- signal_triage_agent(alert)
  risk      <- risk_engine_agent(alert, lookback = lookback)
  knowledge <- retrieve_knowledge(triage$signal_type,
                                  alert$symbol,
                                  risk$risk_level)
  memo <- risk_memo_agent(alert, triage, risk, knowledge,
                          improvement_directives = NULL,
                          previous_memo = NULL,
                          iteration = 1L)

  # Score with the Critic — but DO NOT loop. Quality score is recorded for
  # comparability with V3 (which lets Critic decide whether to re-write).
  critique <- critic_agent(alert, triage, risk, memo, iteration = 1L)

  list(
    alert     = alert,
    triage    = triage,
    risk      = risk,
    knowledge = knowledge,
    memo      = memo,
    quality   = list(
      final_score      = safe_num(critique$quality_score, NA_real_),
      passed           = isTRUE(critique$passes),
      iterations_used  = 1L,
      dimension_scores = critique$dimension_scores
    )
  )
}

# ----------------------------------------------------------------------------
# run_eval_set — runs `pipeline_fn` over each alert and collects stats
# ----------------------------------------------------------------------------
run_eval_set <- function(alerts, label = "v3", pipeline_fn = NULL,
                         lookback = DEFAULT_LOOKBACK,
                         verbose = TRUE) {
  if (is.null(pipeline_fn)) {
    pipeline_fn <- function(a) run_agent_pipeline(a, lookback = lookback)
  }

  rows <- list()
  for (i in seq_along(alerts)) {
    a <- alerts[[i]]
    started <- Sys.time()
    res <- tryCatch(pipeline_fn(a),
                    error = function(e) list(error = conditionMessage(e)))
    finished <- Sys.time()

    q  <- res$quality %||% list()
    ds <- q$dimension_scores %||% list()
    rows[[i]] <- data.frame(
      label             = label,
      eval_id           = safe_chr(a$eval_id, "?"),
      symbol            = safe_chr(a$symbol, "?"),
      event_type        = safe_chr(a$event_type, "?"),
      headline          = safe_chr(res$memo$headline, ""),
      memo              = safe_chr(res$memo$memo, ""),
      action            = safe_chr(res$memo$recommended_action, ""),
      final_score       = safe_num(q$final_score, NA_real_),
      passed            = isTRUE(q$passed),
      iterations_used   = as.integer(q$iterations_used %||% 1L),
      clarity           = safe_num(ds$clarity, NA_real_),
      completeness      = safe_num(ds$completeness, NA_real_),
      actionability     = safe_num(ds$actionability, NA_real_),
      factual_alignment = safe_num(ds$factual_alignment, NA_real_),
      tone              = safe_num(ds$tone, NA_real_),
      latency_s         = as.numeric(difftime(finished, started, units = "secs")),
      degraded          = isTRUE(q$degraded) || isTRUE(res$memo$degraded) ||
                          isTRUE(res$triage$degraded),
      error             = safe_chr(res$error, ""),
      stringsAsFactors  = FALSE
    )
    if (verbose) {
      cat(sprintf("[%s %d/%d] %s — score %.2f%s in %.1fs\n",
                  label, i, length(alerts), a$eval_id,
                  safe_num(q$final_score, NA_real_),
                  if (isTRUE(q$passed)) " PASS" else " fail",
                  rows[[i]]$latency_s))
    }
  }
  do.call(rbind, rows)
}

# ----------------------------------------------------------------------------
# compare_eval_runs — joined diff between v2 and v3 dataframes
# ----------------------------------------------------------------------------
compare_eval_runs <- function(v2_df, v3_df) {
  both <- merge(v2_df, v3_df, by = "eval_id",
                suffixes = c("_v2", "_v3"))
  both$delta_score <- both$final_score_v3 - both$final_score_v2
  both$delta_clarity       <- both$clarity_v3       - both$clarity_v2
  both$delta_completeness  <- both$completeness_v3  - both$completeness_v2
  both$delta_actionability <- both$actionability_v3 - both$actionability_v2
  both$delta_factual       <- both$factual_alignment_v3 - both$factual_alignment_v2
  both$delta_tone          <- both$tone_v3          - both$tone_v2

  summary <- list(
    n              = nrow(both),
    v2_mean_score  = mean(both$final_score_v2, na.rm = TRUE),
    v3_mean_score  = mean(both$final_score_v3, na.rm = TRUE),
    v2_pass_rate   = mean(both$passed_v2, na.rm = TRUE),
    v3_pass_rate   = mean(both$passed_v3, na.rm = TRUE),
    mean_delta     = mean(both$delta_score, na.rm = TRUE),
    n_improved     = sum(both$delta_score > 0, na.rm = TRUE),
    n_degraded     = sum(both$delta_score < 0, na.rm = TRUE),
    v2_mean_latency_s = mean(both$latency_s_v2, na.rm = TRUE),
    v3_mean_latency_s = mean(both$latency_s_v3, na.rm = TRUE),
    pct_v3_iter2   = mean(both$iterations_used_v3 > 1L, na.rm = TRUE)
  )
  list(joined = both, summary = summary)
}

# ----------------------------------------------------------------------------
# write_eval_csvs — persist per-row + summary for slides
# ----------------------------------------------------------------------------
write_eval_csvs <- function(v2_df, v3_df, comparison, dir = NULL) {
  if (is.null(dir)) dir <- file.path(APP_ROOT, "data", "eval")
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)

  utils::write.csv(v2_df,           file.path(dir, "v2_memos.csv"), row.names = FALSE)
  utils::write.csv(v3_df,           file.path(dir, "v3_memos.csv"), row.names = FALSE)
  utils::write.csv(comparison$joined, file.path(dir, "comparison.csv"), row.names = FALSE)

  # Summary as one-row CSV
  utils::write.csv(as.data.frame(comparison$summary, stringsAsFactors = FALSE),
                   file.path(dir, "summary.csv"), row.names = FALSE)

  # Manual scoring template (3 reviewers × N memos)
  manual <- rbind(
    cbind(label = "v2", v2_df[, c("eval_id", "symbol", "event_type",
                                   "headline", "memo", "action")]),
    cbind(label = "v3", v3_df[, c("eval_id", "symbol", "event_type",
                                   "headline", "memo", "action")])
  )
  manual$reviewer_1_score <- NA_integer_
  manual$reviewer_2_score <- NA_integer_
  manual$reviewer_3_score <- NA_integer_
  manual$notes <- ""
  utils::write.csv(manual, file.path(dir, "manual_scores_template.csv"),
                   row.names = FALSE)

  message("Wrote eval CSVs to ", dir)
  invisible(dir)
}

# ----------------------------------------------------------------------------
# run_full_eval — end-to-end (used by scripts/run_eval.R)
# ----------------------------------------------------------------------------
run_full_eval <- function(n_per_event = 1L, lookback = DEFAULT_LOOKBACK,
                          seed = 42L, dir = NULL) {
  if (!nzchar(openai_key())) {
    stop("OPENAI_API_KEY required to run the eval harness.")
  }

  message("Building eval alert set (n_per_event = ", n_per_event, ")...")
  alerts <- build_eval_alert_set(n_per_event = n_per_event,
                                 lookback = lookback, seed = seed)
  message("  ", length(alerts), " alerts")

  message("Running V2-compat pipeline...")
  v2_df <- run_eval_set(alerts, label = "v2",
                        pipeline_fn = function(a) v2_compat_pipeline(a, lookback))

  message("Running V3 pipeline (with critic loop)...")
  v3_df <- run_eval_set(alerts, label = "v3",
                        pipeline_fn = function(a) run_agent_pipeline(a, lookback = lookback))

  cmp <- compare_eval_runs(v2_df, v3_df)

  message("\nSummary:")
  for (key in names(cmp$summary)) {
    message(sprintf("  %s: %s", key, format(cmp$summary[[key]], digits = 4)))
  }

  write_eval_csvs(v2_df, v3_df, cmp, dir = dir)

  invisible(list(v2 = v2_df, v3 = v3_df, comparison = cmp))
}
