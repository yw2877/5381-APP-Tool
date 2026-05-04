# ============================================================================
# R/server.R — V3 server
# ============================================================================

# ========== Helpers ==========

empty_risk <- function(symbol, message = "") {
  list(
    error            = TRUE,
    message          = message,
    symbol           = symbol,
    risk_level       = "monitor",
    latest_price     = NA_real_,
    rolling_vol_20d  = NA_real_,
    max_drawdown     = NA_real_,
    var_1d           = NA_real_,
    es_1d            = NA_real_,
    var_5d           = NA_real_,
    es_5d            = NA_real_,
    correlation_jump = NA_real_,
    regime_score     = NA_real_,
    primary_driver   = "N/A"
  )
}

format_case_meta <- function(case_row) {
  parts <- c()
  for (key in c("case_date", "asset_focus", "market_regime", "event_type")) {
    if (key %in% names(case_row)) {
      val <- safe_chr(case_row[[key]][[1]], default = "")
      if (nzchar(val)) {
        parts <- c(parts,
                   if (key == "event_type") title_case(val) else val)
      }
    }
  }
  paste(parts, collapse = " | ")
}

render_historical_case_cards <- function(cases, empty_message = "No cases found.") {
  if (!nrow(cases)) return(p(empty_message))

  lapply(seq_len(nrow(cases)), function(i) {
    case_row <- cases[i, , drop = FALSE]
    meta_line <- format_case_meta(case_row)

    div(
      class = "knowledge-card muted",
      if (nzchar(meta_line)) div(class = "knowledge-kicker", meta_line),
      div(class = "knowledge-title",
          safe_chr(case_row$case_name[[1]], default = "Untitled case")),
      p(class = "knowledge-copy",
        safe_chr(case_row$summary[[1]], default = "")),
      if ("watch_items" %in% names(case_row) &&
          nzchar(safe_chr(case_row$watch_items[[1]], default = ""))) {
        p(class = "knowledge-foot",
          paste("Watch:", safe_chr(case_row$watch_items[[1]], default = "")))
      }
    )
  })
}

# Time-window cutoff for Quality Dashboard
qd_window_cutoff <- function(window) {
  switch(safe_chr(window, default = "all"),
    "1h"  = Sys.time() - 60 * 60,
    "24h" = Sys.time() - 24 * 60 * 60,
    "7d"  = Sys.time() - 7 * 24 * 60 * 60,
    NULL
  )
}

# ========== Asset Dashboard Module Server ==========

assetDashboardServer <- function(id, parent_session = NULL) {
  moduleServer(id, function(input, output, session) {

    selected_lookback <- reactive(as.integer(input$lookback %||% DEFAULT_LOOKBACK))
    current_asset     <- reactive(asset_row(input$asset))

    alerts_data <- reactivePoll(
      intervalMillis = 5000,
      session        = session,
      checkFunc      = function() {
        if (!file.exists(APP_DB_PATH)) return(0)
        as.numeric(file.info(APP_DB_PATH)$mtime)
      },
      valueFunc = function() fetch_alert_history(limit = 200L)
    )

    refresh_trigger <- reactiveVal(0)
    observeEvent(input$refresh_btn, refresh_trigger(refresh_trigger() + 1))

    # ── Reactive 1: Yahoo Finance market data ──────────────────────────────
    market_risk <- reactive({
      req(input$asset)
      tryCatch(
        compute_risk_metrics(input$asset, lookback = selected_lookback()),
        error = function(e) empty_risk(input$asset, conditionMessage(e))
      )
    }) |> bindCache(input$asset, selected_lookback(), refresh_trigger())

    price_history <- reactive({
      req(input$asset)
      tryCatch(
        get_price_history(input$asset, lookback = selected_lookback()),
        error = function(e) NULL
      )
    }) |> bindCache(input$asset, selected_lookback(), refresh_trigger())

    # ── Reactive 2: latest stored analysis (from DB) ────────────────────────
    latest_stored_analysis <- reactive({
      req(input$asset)
      input$asset; alerts_data(); refresh_trigger()
      tryCatch(
        fetch_latest_analysis(symbol = input$asset),
        error = function(e) NULL
      )
    })

    latest_quality <- reactive({
      stored <- latest_stored_analysis()
      if (is.null(stored$alert$alert_id)) return(NULL)
      tryCatch(
        fetch_quality_score_for_alert(stored$alert$alert_id),
        error = function(e) NULL
      )
    })

    # ── Reactive 3: AI analysis (prefer stored; else baseline if key) ──────
    ai_analysis <- reactive({
      req(input$asset)

      stored <- latest_stored_analysis()
      if (!is.null(stored)) {
        # Async webhook may have written the alert row but not the analyses
        # row yet. Surface a "pipeline running" state so the UI can show a
        # loading banner instead of crashing on missing fields.
        status <- stored$status %||% "complete"
        if (identical(status, "pending") || identical(status, "partial")) {
          return(list(
            error           = FALSE,
            api_key_missing = FALSE,
            source          = "loading",
            status          = status,
            message         = if (identical(status, "partial"))
              "Pipeline still running for this alert — partial results stored. Refresh in a few seconds."
            else
              "Pipeline running for this alert — agents have not finished yet. Refresh in a few seconds.",
            alert     = stored$alert,
            triage    = stored$triage,    # may be NULL
            memo      = stored$memo,      # has empty strings if pending
            knowledge = stored$knowledge,
            risk      = stored$risk,
            quality   = NULL
          ))
        }
        q <- latest_quality()
        return(list(
          error           = FALSE,
          api_key_missing = FALSE,
          source          = "stored",
          status          = status,
          message         = NULL,
          alert     = stored$alert,
          triage    = stored$triage,
          memo      = stored$memo,
          knowledge = stored$knowledge,
          risk      = stored$risk,
          quality   = q
        ))
      }

      if (!nzchar(openai_key())) {
        return(list(
          error           = TRUE,
          api_key_missing = TRUE,
          source          = "empty",
          message         = "No stored memo for this asset yet. Set OPENAI_API_KEY in your .env (copy from .env.example), restart the app, then click Simulate.",
          alert = NULL, triage = NULL, memo = NULL,
          knowledge = NULL, risk = NULL, quality = NULL
        ))
      }

      # No stored analysis, but key is present → run baseline pipeline.
      input$asset; selected_lookback(); refresh_trigger()
      alert <- baseline_alert(input$asset)
      tryCatch({
        analysis <- run_agent_pipeline(alert,
                                       lookback = selected_lookback())
        list(
          error           = FALSE,
          api_key_missing = FALSE,
          source          = "baseline",
          message         = NULL,
          alert     = analysis$alert,
          triage    = analysis$triage,
          memo      = analysis$memo,
          knowledge = analysis$knowledge,
          risk      = analysis$risk,
          quality   = analysis$quality
        )
      }, error = function(e) {
        list(
          error = TRUE, api_key_missing = FALSE,
          source = "baseline_error", message = conditionMessage(e),
          alert = alert, triage = NULL, memo = NULL,
          knowledge = NULL, risk = market_risk(), quality = NULL
        )
      })
    })

    # ── Simulate Alert ──────────────────────────────────────────────────────
    observeEvent(input$simulate_alert, {
      if (!nzchar(openai_key())) {
        showNotification(
          "Add OPENAI_API_KEY to your .env file and restart the app.",
          type = "warning", duration = 6
        )
        # Allow simulating into degraded mode anyway, so demo still works.
      }

      withProgress(
        message = "Running agent pipeline...",
        value   = 0.1,
        detail  = "triage → risk → memo → critic",
        {
          tryCatch({
            payload <- build_simulated_alert(
              input$asset,
              lookback   = selected_lookback(),
              event_type = input$scenario
            )
            setProgress(0.4, detail = "calling agents")
            result <- process_and_store_alert(payload,
                                              lookback = selected_lookback())
            setProgress(0.95, detail = "done")
            refresh_trigger(refresh_trigger() + 1)

            q <- result$analysis$quality
            verdict <- if (isTRUE(q$passed)) "✓ passed" else "✗ failed"
            iters   <- q$iterations_used %||% 1L
            score   <- format_number(q$final_score %||% NA_real_, 0.01)

            showNotification(
              glue("Alert #{result$alert_id} — {verdict}  ·  score {score}  ·  {iters} iter"),
              type = if (isTRUE(q$passed)) "message" else "warning",
              duration = 8
            )
          }, error = function(e) {
            showNotification(
              paste("Simulation error:", conditionMessage(e)),
              type = "error", duration = 10
            )
          })
        }
      )
    })

    # ── Error / status banner ───────────────────────────────────────────────
    output$error_banner <- renderUI({
      ai  <- ai_analysis()
      mkt <- market_risk()
      banners <- list()

      if (isTRUE(mkt$error)) {
        banners <- c(banners, list(
          div(class = "error-banner",
            div(class = "error-icon", icon("database")),
            div(class = "error-msg",
              strong("Market data error — "), mkt$message)
          )
        ))
      }

      if (identical(ai$source, "loading")) {
        banners <- c(banners, list(
          div(class = "error-banner warning-banner",
            div(class = "error-icon", icon("hourglass-half")),
            div(class = "error-msg",
              strong("Pipeline running — "), ai$message)
          )
        ))
      }

      if (isTRUE(ai$error)) {
        icon_name <- if (isTRUE(ai$api_key_missing)) "key" else "circle-xmark"
        banners <- c(banners, list(
          div(class = "error-banner",
            div(class = "error-icon", icon(icon_name)),
            div(class = "error-msg",
              strong(if (isTRUE(ai$api_key_missing))
                       "OpenAI API key not configured — "
                     else
                       "Agent error — "),
              ai$message)
          )
        ))
      }

      # Surface degraded path
      if (!isTRUE(ai$error) &&
          (isTRUE(ai$triage$degraded) || isTRUE(ai$memo$degraded) ||
           isTRUE(ai$quality$degraded))) {
        banners <- c(banners, list(
          div(class = "error-banner warning-banner",
            div(class = "error-icon", icon("triangle-exclamation")),
            div(class = "error-msg",
              strong("Degraded mode — "),
              "OpenAI was unavailable for at least one agent. Showing deterministic fallback output.")
          )
        ))
      }

      if (length(banners) == 0) return(NULL)
      do.call(tagList, banners)
    })

    # ── Risk badge (market data) ────────────────────────────────────────────
    output$risk_badge <- renderUI({
      level <- market_risk()$risk_level %||% "monitor"
      div(class = paste("risk-pill", risk_badge_class(level)),
          toupper(safe_chr(level, default = "monitor")))
    })

    # ── Asset meta line in app-header breadcrumb ("120D · bollinger_breakdown")
    output$asset_meta <- renderText({
      lookback <- safe_chr(input$lookback, default = DEFAULT_LOOKBACK)
      scenario <- safe_chr(input$scenario, default = "random")
      paste0(lookback, " · ", scenario)
    })

    # ── KPI boxes ─────────────────────────────────────────────────
    output$kpi_price <- renderUI({
      div(class = "kpi-value",
          format_dollar(market_risk()$latest_price, accuracy = 0.01))
    })
    output$kpi_vol <- renderUI({
      div(class = "kpi-value",
          format_pct(market_risk()$rolling_vol_20d))
    })
    output$kpi_dd <- renderUI({
      div(class = "kpi-value warning",
          format_pct(market_risk()$max_drawdown))
    })
    output$kpi_var <- renderUI({
      div(class = "kpi-value",
          format_pct(market_risk()$var_1d))
    })
    output$kpi_regime <- renderUI({
      score <- market_risk()$regime_score
      cls   <- if (safe_num(score, 0) >= 0.6) "kpi-value warning" else "kpi-value"
      div(class = cls, format_number(score, accuracy = 0.01))
    })
    output$kpi_last_alert <- renderUI({
      latest <- latest_stored_analysis()
      div(
        class = "kpi-value small",
        if (!is.null(latest) && !is.null(latest$alert))
          format_ts(latest$alert$received_at)
        else "No alerts yet"
      )
    })

    # ── TradingView chart (lazy: don't render when tab hidden) ─────────────
    output$tv_chart <- renderUI({
      tv_widget_html(tv_symbol = current_asset()$tv_symbol[[1]])
    })
    outputOptions(output, "tv_chart", suspendWhenHidden = TRUE)

    # ── Agent Pipeline · Trace ────────────────────────────────────────────
    # Renders one row per agent_runs entry for the current alert. Each row =
    # numbered badge + agent name + one-line output + latency + status pill.
    # When the Critic forced a rewrite, you'll see iter-1 fail then iter-2 pass.
    .agent_label <- function(name, iter) {
      base <- switch(name,
        "triage"      = "Triage",
        "risk_engine" = "Risk Engine",
        "memo"        = "Memo",
        "memo_retry"  = "Memo",
        "critic"      = "Critic",
        title_case(name)
      )
      iter_n <- safe_num(iter, 1L)
      if (is.finite(iter_n) && iter_n > 1L) {
        return(paste0(base, " (", as.integer(iter_n), ")"))
      }
      if (name %in% c("memo", "critic", "memo_retry") && is.finite(iter_n))
        paste0(base, " (", as.integer(iter_n), ")")
      else base
    }

    .agent_color_class <- function(name) {
      switch(name,
        "triage"      = "color-blue",
        "risk_engine" = "color-purple",
        "memo"        = "color-amber",
        "memo_retry"  = "color-amber",
        "critic"      = "color-acid",
        "color-blue"
      )
    }

    output$agent_trace_html <- renderUI({
      stored <- latest_stored_analysis()
      alert_id <- stored$alert$alert_id %||% NULL
      if (is.null(alert_id)) {
        return(div(class = "agent-trace empty",
          div(class = "agent-trace__empty-icon", icon("circle-nodes")),
          div(class = "agent-trace__empty-msg",
              "No pipeline run yet. Click ⚡ Simulate to fire the agentic loop.")
        ))
      }
      runs <- tryCatch(fetch_agent_runs_for_alert(alert_id),
                       error = function(e) data.frame())
      if (!is.data.frame(runs) || nrow(runs) == 0) {
        return(div(class = "agent-trace empty",
          div(class = "agent-trace__empty-icon", icon("circle-nodes")),
          div(class = "agent-trace__empty-msg",
              "Pipeline ran but agent_runs is empty for this alert.")
        ))
      }
      runs <- runs[order(runs$id), , drop = FALSE]

      # quality info — used to color the *final* row's status if available
      q <- latest_quality()
      final_pass <- isTRUE(q$passed)
      final_score <- safe_num(q$final_score, NA_real_)

      rows <- lapply(seq_len(nrow(runs)), function(i) {
        r <- runs[i, , drop = FALSE]
        name      <- safe_chr(r$agent_name, default = "agent")
        iter      <- safe_num(r$iteration, 1L)
        latency   <- safe_num(r$latency_ms, NA_real_)
        validated <- isTRUE(safe_num(r$validation_passed, 0) > 0)
        err_class <- safe_chr(r$error_class, default = "")
        is_critic <- identical(name, "critic")
        is_last   <- (i == nrow(runs))

        # Status pill logic
        if (nzchar(err_class)) {
          status_label <- "ERR"
          status_cls   <- "pill-fail"
        } else if (is_critic && is_last) {
          # Final critic verdict drives PASS/FAIL
          if (is.finite(final_score) && final_pass) {
            status_label <- "PASS"; status_cls <- "pill-pass"
          } else {
            status_label <- "FAIL"; status_cls <- "pill-fail"
          }
        } else if (is_critic) {
          # Mid-loop critic = the failing one that triggered retry
          status_label <- "FAIL"; status_cls <- "pill-fail"
        } else {
          status_label <- "OK"; status_cls <- "pill-pass"
        }

        # Output line: a small one-line description
        out_line <- if (is_critic) {
          if (is_last && is.finite(final_score)) {
            sprintf("score %.2f — %s",
                    final_score,
                    if (final_pass) "passed" else "rewrite directive issued")
          } else {
            "rewrite directive issued"
          }
        } else if (name %in% c("memo", "memo_retry")) {
          sprintf("iter %d — %d tokens",
                  as.integer(iter),
                  as.integer(safe_num(r$completion_tokens, 0)))
        } else if (identical(name, "risk_engine")) {
          "tool: compute_risk_metrics()"
        } else if (identical(name, "triage")) {
          tri <- stored$triage
          stype <- safe_chr(tri$signal_type, default = "")
          sev   <- safe_chr(tri$severity_hint, default = "")
          conf  <- safe_num(tri$confidence, NA_real_)
          parts <- c()
          if (nzchar(stype)) parts <- c(parts, stype)
          if (nzchar(sev))   parts <- c(parts, sev)
          if (is.finite(conf) && conf > 0) parts <- c(parts, sprintf("%.0f%%", conf * 100))
          if (length(parts) == 0) "classified" else paste(parts, collapse = " · ")
        } else {
          name
        }

        latency_str <- if (is.finite(latency)) sprintf("%dms", as.integer(latency)) else "—"

        div(class = "agent-trace__row",
          div(class = "agent-trace__lhs",
            span(class = paste("agent-trace__num", .agent_color_class(name)),
                 as.character(i)),
            span(class = "agent-trace__name", .agent_label(name, iter))
          ),
          div(class = "agent-trace__out", out_line),
          div(class = "agent-trace__rhs",
            span(class = "agent-trace__meta", latency_str),
            span(class = paste("pill", status_cls), status_label)
          )
        )
      })

      div(class = "agent-trace", rows)
    })

    # Header meta line: "{n_total} ms total · ↻ {n_retries} retry"
    output$agent_trace_meta <- renderUI({
      stored <- latest_stored_analysis()
      alert_id <- stored$alert$alert_id %||% NULL
      if (is.null(alert_id)) return(NULL)
      runs <- tryCatch(fetch_agent_runs_for_alert(alert_id),
                       error = function(e) data.frame())
      if (!is.data.frame(runs) || nrow(runs) == 0) return(NULL)
      total <- sum(safe_num(runs$latency_ms, 0), na.rm = TRUE)
      retries <- sum(grepl("retry", runs$agent_name, fixed = TRUE), na.rm = TRUE)
      span(
        class = "agent-trace__meta",
        sprintf("%s ms total · ↻ %d retr%s",
                format(round(total), big.mark = ","),
                as.integer(retries),
                if (retries == 1L) "y" else "ies")
      )
    })

    # ── Quality Snapshot card (replaces V2 Risk Metrics Snapshot bar) ───────
    output$quality_snapshot <- renderUI({
      ai <- ai_analysis()
      q  <- ai$quality

      if (is.null(q) || is.null(q$final_score) ||
          !is.finite(safe_num(q$final_score, NA_real_))) {
        return(div(class = "quality-snapshot empty",
          div(class = "qs-icon", icon("hourglass-half")),
          div(class = "qs-msg", "No quality score yet. Click Simulate to run the pipeline.")
        ))
      }

      score   <- safe_num(q$final_score, 0)
      passed  <- isTRUE(q$passed)
      iters   <- q$iterations_used %||% 1L
      ds      <- q$dimension_scores %||% list()

      pill_cls <- if (passed) "qs-pass" else "qs-fail"
      pill_txt <- if (passed) "PASSED" else "FAILED"

      bars <- function(label, val) {
        v <- safe_num(val, 0)
        tier <- if (v >= 0.80) "pass" else if (v >= 0.75) "warn" else "fail"
        div(class = "qs-dim",
          div(class = "qs-dim-head",
            div(class = "qs-dim-label", label),
            div(class = paste("qs-dim-val", tier), format_number(v, 0.01))
          ),
          div(class = "qs-dim-bar-wrap",
            div(class = paste("qs-dim-bar", tier),
                style = sprintf("width:%.0f%%;", v * 100))
          )
        )
      }

      issues <- as.list(q$issues %||% list())
      first_issue <- if (length(issues) > 0)
        safe_chr(issues[[1]], default = "") else ""

      tagList(
        div(class = "qs-top",
          div(class = paste("qs-pill", pill_cls), pill_txt),
          div(class = "qs-score",
            span(class = "qs-score-num", format_number(score, 0.01)),
            span(class = "qs-score-suffix", "/ 1.00")),
          div(class = "qs-iter",
            span(class = "qs-iter-num", as.character(iters)),
            span(class = "qs-iter-label",
                 if (iters > 1L) "iterations" else "iteration"))
        ),
        bars("Clarity",          ds$clarity),
        bars("Completeness",     ds$completeness),
        bars("Actionability",    ds$actionability),
        bars("Factual Alignment", ds$factual_alignment),
        bars("Tone",             ds$tone),
        if (!passed && nzchar(first_issue))
          div(class = "qs-issue",
            strong("Top issue: "), first_issue)
      )
    })

    # ── Signal Triage Agent panel ──────────────────────────────────────────
    output$triage_panel <- renderUI({
      ai <- ai_analysis()
      if (isTRUE(ai$error)) {
        return(div(class = "agent-placeholder",
          div(class = "placeholder-icon", icon(
            if (isTRUE(ai$api_key_missing)) "key" else "circle-xmark")),
          div(class = "placeholder-msg", ai$message)
        ))
      }
      triage <- ai$triage
      alert  <- ai$alert
      summary_items <- list(
        list(label = "Event Type",   value = title_case(safe_chr(alert$event_type,    "baseline_check"))),
        list(label = "Signal Type",  value = title_case(safe_chr(triage$signal_type,  "watchlist_signal"))),
        list(label = "Trigger",      value = format_dollar(alert$trigger_price, accuracy = 0.01)),
        list(label = "Severity",     value = toupper(safe_chr(triage$severity_hint,   "medium"))),
        list(label = "Received",     value = format_ts(alert$received_at))
      )
      tagList(
        div(class = "triage-summary-grid",
          lapply(summary_items, function(item)
            div(class = "triage-summary-box",
              div(class = "triage-summary-label", item$label),
              div(class = "triage-summary-value", item$value)))
        ),
        p(class = "agent-copy", safe_chr(triage$rationale, default = "")),
        div(class = "focus-list",
          lapply(triage$suggested_focus, function(item)
            div(class = "focus-chip", safe_chr(item, default = "watch")))
        )
      )
    })

    # ── Risk Engine Agent panel ─────────────────────────
    output$risk_metrics_panel <- renderUI({
      risk <- market_risk()
      div(class = "metric-grid",
        metric_box("Latest Price",   format_dollar(risk$latest_price, accuracy = 0.01)),
        metric_box("20D Vol",        format_pct(risk$rolling_vol_20d)),
        metric_box("Max Drawdown",   format_pct(risk$max_drawdown)),
        metric_box("1D VaR",         format_pct(risk$var_1d)),
        metric_box("1D ES",          format_pct(risk$es_1d)),
        metric_box("Corr Jump",      format_number(risk$correlation_jump, accuracy = 0.01)),
        metric_box("Regime Score",   format_number(risk$regime_score,     accuracy = 0.01)),
        metric_box("Primary Driver", title_case(risk$primary_driver))
      )
    })

    # ── Risk Memo Agent panel ──────────────────────────────────────────────
    output$memo_panel <- renderUI({
      ai <- ai_analysis()
      if (isTRUE(ai$error)) {
        return(div(class = "agent-placeholder",
          div(class = "placeholder-icon", icon(
            if (isTRUE(ai$api_key_missing)) "key" else "circle-xmark")),
          div(class = "placeholder-msg", ai$message)
        ))
      }
      memo <- ai$memo
      tagList(
        div(class = "memo-headline",
            safe_chr(memo$headline, default = "No memo available")),
        tags$pre(class = "memo-body",
            safe_chr(memo$memo, default = "")),
        if (!is.null(memo$recommended_action) &&
            nzchar(safe_chr(memo$recommended_action, "")))
          div(class = "memo-action",
              strong("Next step: "), memo$recommended_action)
      )
    })

    # ── Critic Agent panel ─────────────────────────────────────────────────
    output$critic_panel <- renderUI({
      ai <- ai_analysis()
      q  <- ai$quality
      if (is.null(q)) {
        return(div(class = "agent-placeholder",
          div(class = "placeholder-icon", icon("hourglass-half")),
          div(class = "placeholder-msg",
              "No critique yet. Click Simulate.")
        ))
      }

      iters <- q$iteration_history %||% list()
      issues <- as.list(q$issues %||% list())
      directives <- safe_chr(q$improvement_directives, "")

      tagList(
        div(class = "critic-summary",
          div(class = "critic-verdict",
              span(class = if (isTRUE(q$passed)) "qs-pill qs-pass" else "qs-pill qs-fail",
                   if (isTRUE(q$passed)) "PASSED" else "FAILED"),
              span(class = "qs-score",
                   span(class = "qs-score-num",
                        format_number(q$final_score, 0.01)),
                   span(class = "qs-score-suffix", "/ 1.00"))),
          div(class = "critic-meta",
              "Final score after ",
              strong(as.character(q$iterations_used %||% 1L)),
              if ((q$iterations_used %||% 1L) > 1L) " iterations" else " iteration",
              ".")
        ),
        if (length(issues) > 0)
          div(class = "critic-issues",
            div(class = "section-label", "Issues"),
            tags$ul(lapply(issues, function(i) tags$li(safe_chr(i, ""))))
          ),
        if (nzchar(directives))
          div(class = "critic-directives",
            div(class = "section-label", "Improvement Directives"),
            tags$pre(class = "memo-body", directives)
          ),
        if (length(iters) > 1)
          div(class = "iteration-history",
            div(class = "section-label top-space", "Iteration History"),
            lapply(seq_along(iters), function(i) {
              it <- iters[[i]]
              div(class = "iteration-card",
                div(class = "iteration-header",
                    paste0("Iteration ", i),
                    span(class = "iteration-score",
                         "score ",
                         format_number(it$critique$quality_score, 0.01))),
                div(class = "iteration-headline",
                    safe_chr(it$memo$headline, "")),
                p(class = "iteration-memo",
                  safe_chr(it$memo$memo, ""))
              )
            })
          )
      )
    })

    # ── Plotly: Price + Rolling Volatility ─────────────────────────────────
    output$price_vol_chart <- renderPlotly({
      ph <- price_history()
      if (is.null(ph)) {
        return(plotly::plot_ly() |> plotly::layout(
          annotations = list(list(
            text = "Price data unavailable", xref = "paper", yref = "paper",
            x = 0.5, y = 0.5, showarrow = FALSE,
            font = list(size = 13, color = "#ff5470")
          )),
          paper_bgcolor = "rgba(0,0,0,0)"
        ) |> apply_plotly_dark() |> plotly::config(displayModeBar = FALSE, displaylogo = FALSE))
      }

      prices  <- ph[!is.na(ph$ret), ]
      n       <- nrow(prices)
      vol_vec <- rep(NA_real_, n)
      if (n >= 20) {
        for (i in seq(20, n))
          vol_vec[i] <- sd(prices$ret[(i - 19):i], na.rm = TRUE) * sqrt(252)
      }
      prices$vol20 <- vol_vec

      p1 <- plotly::plot_ly(
        prices, x = ~date, y = ~close,
        type = "scatter", mode = "lines", name = "Price",
        line = list(color = "#a3ff12", width = 2)
      ) |> plotly::layout(yaxis = list(title = "Price"))

      p2 <- plotly::plot_ly(
        prices, x = ~date, y = ~vol20,
        type = "scatter", mode = "lines", name = "20D Vol",
        line = list(color = "#7e8593", width = 1.5)
      ) |> plotly::layout(yaxis = list(title = "Ann. Vol", tickformat = ".0%"))

      plotly::subplot(p1, p2, nrows = 2, shareX = TRUE,
        heights = c(0.65, 0.35), titleY = TRUE) |>
        plotly::layout(
          paper_bgcolor = "rgba(0,0,0,0)",
          plot_bgcolor  = "rgba(0,0,0,0)",
          legend = list(orientation = "h", y = -0.05),
          margin = list(l = 50, r = 20, t = 10, b = 30),
          autosize = TRUE
        ) |>
        apply_plotly_dark() |>
        plotly::config(displayModeBar = FALSE, displaylogo = FALSE,
                       responsive = TRUE)
    })

    # ── Recent Alerts (compact, last 5) ────────────────────────────────────
    output$alert_history <- renderDT({
      history <- alerts_data()
      if (nrow(history) > 0 && "symbol" %in% names(history))
        history <- history[history$symbol == input$asset, , drop = FALSE]
      if (!nrow(history)) {
        history <- tibble::tibble(
          received_at = character(), event_type = character(),
          risk_level = character(), primary_driver = character(),
          trigger_price = character()
        )
      }
      if ("trigger_price" %in% names(history))
        history$trigger_price <- vapply(history$trigger_price, format_dollar,
                                        character(1), accuracy = 0.01)
      cols <- intersect(
        c("received_at", "event_type",
          "risk_level", "primary_driver", "trigger_price"),
        names(history)
      )
      DT::datatable(history[, cols, drop = FALSE], rownames = FALSE,
        class   = "compact stripe hover",
        options = list(pageLength = 5, dom = "t",
                       ordering = FALSE, scrollX = TRUE))
    }, server = FALSE)

    # Belt-and-braces: explicitly mark heavy outputs as suspended when their
    # tabPanelBody is hidden. Default is TRUE in modern Shiny but type="hidden"
    # tabsets sometimes mis-detect visibility; making it explicit is cheap.
    for (oid in c("tv_chart", "price_vol_chart", "alert_history",
                  "agent_trace_html", "quality_snapshot",
                  "triage_panel", "risk_metrics_panel",
                  "memo_panel", "critic_panel",
                  "kpi_price", "kpi_vol", "kpi_dd", "kpi_var",
                  "kpi_regime", "kpi_last_alert")) {
      outputOptions(output, oid, suspendWhenHidden = TRUE)
    }

  }) # end moduleServer
}

# ============================================================================
# Quality Score lookup helper  (used by assetDashboardServer)
# ============================================================================
fetch_quality_score_for_alert <- function(alert_id) {
  if (is.null(alert_id) || is.na(alert_id)) return(NULL)
  conn <- db_connect()
  on.exit(DBI::dbDisconnect(conn), add = TRUE)
  row <- DBI::dbGetQuery(conn, sprintf(
    "SELECT * FROM quality_scores WHERE alert_id = %d LIMIT 1;",
    as.integer(alert_id)))
  if (!nrow(row)) return(NULL)

  list(
    final_score      = safe_num(row$final_score, NA_real_),
    passed           = isTRUE(as.logical(row$passed)),
    iterations_used  = as.integer(row$iterations_used),
    dimension_scores = list(
      clarity           = safe_num(row$clarity,           NA_real_),
      completeness      = safe_num(row$completeness,      NA_real_),
      actionability     = safe_num(row$actionability,     NA_real_),
      factual_alignment = safe_num(row$factual_alignment, NA_real_),
      tone              = safe_num(row$tone,              NA_real_)
    ),
    iteration_history = parse_json_safely(row$iteration_history_json) %||% list(),
    issues = list(),
    improvement_directives = "",
    degraded = isTRUE(as.logical(row$degraded))
  )
}

# ============================================================================
# Cross-asset risk table (parallelized)
# ============================================================================
compute_cross_asset_risk_raw <- function() {
  # Serial Yahoo fetch. Previous furrr::future_map(workers = 4) approach
  # spawned 4 R subprocesses, each re-loading the full package stack
  # (~300-500 MB each). On a 1 GB droplet that pushed total RSS over the
  # cgroup limit and the app got OOM-killed during cross-asset render.
  # Serial is ~3-5s slower for first uncached load but uses no extra RAM.
  syms <- APP_ASSETS$label
  rows <- lapply(syms, function(sym) {
    tryCatch(compute_risk_metrics(sym, lookback = 120L),
             error = function(e) empty_risk(sym, conditionMessage(e)))
  })
  names(rows) <- syms
  rows
}

compute_cross_asset_risk_table <- function(raw = NULL) {
  if (is.null(raw)) raw <- compute_cross_asset_risk_raw()
  syms <- names(raw)

  do.call(rbind, lapply(seq_along(syms), function(i) {
    sym <- syms[[i]]; m <- raw[[i]]
    data.frame(
      Symbol        = sym,
      `Asset Class` = APP_ASSETS$asset_class[APP_ASSETS$label == sym],
      Price         = format_dollar(m$latest_price, accuracy = 0.01),
      `20D Vol`     = format_pct(m$rolling_vol_20d),
      `Max DD`      = format_pct(m$max_drawdown),
      `VaR 1D`      = format_pct(m$var_1d),
      `ES 1D`       = format_pct(m$es_1d),
      `Regime`      = format_number(m$regime_score, accuracy = 0.01),
      `Risk Level`  = toupper(safe_chr(m$risk_level, "monitor")),
      `Driver`      = title_case(safe_chr(m$primary_driver, "baseline")),
      check.names = FALSE, stringsAsFactors = FALSE
    )
  }))
}

# ============================================================================
# App Server
# ============================================================================
app_server <- function(input, output, session) {

  assetDashboardServer("crypto", parent_session = session)
  assetDashboardServer("equity", parent_session = session)

  # ---------- Welcome modal ----------
  observeEvent(input$show_welcome, {
    showModal(welcome_modal())
  })
  # Persist "don't show again" via JS → localStorage
  observeEvent(input$welcome_dont_show, {
    if (isTRUE(input$welcome_dont_show)) {
      session$sendCustomMessage("set_welcome_seen", TRUE)
    }
  }, ignoreInit = TRUE)

  # ---------- Agent prompt modal ----------
  observeEvent(input$show_prompt, {
    m <- agent_prompt_modal(input$show_prompt)
    if (!is.null(m)) showModal(m)
  })

  # ---------- Sidebar (app shell) ----------
  output$app_sidebar_ui <- renderUI({
    active <- input$main_nav %||% "equities"
    app_sidebar(active_value = active)
  })

  # Sidebar click → switch hidden tabset
  observeEvent(input$nav_to, {
    valid <- c("equities", "crypto", "risk", "quality", "alerts")
    target <- input$nav_to
    if (!is.null(target) && target %in% valid) {
      updateTabsetPanel(session, "main_nav", selected = target)
    }
  }, ignoreInit = TRUE)

  # System status card at the bottom of the sidebar — last-hour aggregates
  # from agent_runs. Polls every 30s so it reflects recent activity.
  sys_status_poll <- reactivePoll(
    intervalMillis = 30000,
    session = session,
    checkFunc = function() Sys.time(),
    valueFunc = function() {
      tryCatch(
        fetch_agent_runs(since = Sys.time() - 3600, limit = 5000L),
        error = function(e) data.frame()
      )
    }
  )

  output$sys_status_card <- renderUI({
    runs <- sys_status_poll()
    if (!is.data.frame(runs) || nrow(runs) == 0) {
      return(tagList(
        div(class = "sys-status__label", "SYSTEM"),
        div(class = "sys-status__ok", "Idle"),
        div(class = "sys-status__meta", "no runs in last hour")
      ))
    }
    p95 <- tryCatch(
      stats::quantile(runs$latency_ms, 0.95, na.rm = TRUE),
      error = function(e) NA_real_
    )
    err <- tryCatch(
      mean(!is.na(runs$error_class), na.rm = TRUE),
      error = function(e) NA_real_
    )
    healthy <- is.finite(err) && err < 0.05
    headline_cls <- if (healthy) "sys-status__ok" else "sys-status__ok sys-status__ok--warn"
    headline_txt <- if (healthy) "All agents OK" else "Errors detected"

    p95_str <- if (is.finite(p95)) sprintf("%s ms", format(round(p95), big.mark = ",")) else "—"
    err_str <- if (is.finite(err)) sprintf("%.1f%%", err * 100) else "—"

    tagList(
      div(class = "sys-status__label", "SYSTEM"),
      div(class = headline_cls, headline_txt),
      div(class = "sys-status__meta",
          sprintf("p95 %s · err %s", p95_str, err_str))
    )
  })

  # ---------- Cross-page navigation ----------
  observeEvent(input$go_to_ops, {
    updateTabsetPanel(session, "main_nav", selected = "alerts")
  })

  # ---------- Risk Overview ----------
  cross_asset_raw <- reactive({
    invalidateLater(5 * 60 * 1000, session)   # refresh every 5 min
    compute_cross_asset_risk_raw()
  })

  output$overview_risk_table <- renderDT({
    df <- compute_cross_asset_risk_table(cross_asset_raw())
    DT::datatable(df, rownames = FALSE, class = "compact stripe",
      options = list(dom = "t", ordering = FALSE, pageLength = 10))
  })

  # Top of page: one card per asset, regime-colored top border + sparkline data.
  output$overview_asset_cards <- renderUI({
    raw <- cross_asset_raw()
    if (length(raw) == 0) return(NULL)

    cards <- lapply(seq_along(raw), function(i) {
      sym <- names(raw)[[i]]
      m   <- raw[[i]]

      regime <- safe_num(m$regime_score, 0)
      tier   <- if (regime > 0.6) "high" else if (regime > 0.4) "med" else "low"
      tier_label <- toupper(tier)

      price_chg <- safe_num(m$latest_price_chg %||% NA_real_, 0)  # may not exist; fallback 0
      price <- m$latest_price
      vol <- safe_num(m$rolling_vol_20d, NA_real_)
      dd  <- safe_num(m$max_drawdown, NA_real_)
      var_1 <- safe_num(m$var_1d, NA_real_)

      div(class = paste("asset-card", paste0("asset-card--", tier)),
        div(class = "asset-card__head",
          span(class = "asset-card__sym", sym),
          span(class = paste("asset-card__pill", paste0("asset-card__pill--", tier)),
               tier_label)
        ),
        div(class = "asset-card__price",
          if (is.finite(safe_num(price, NA_real_)))
            format_dollar(price, accuracy = 0.01)
          else "—"),
        div(class = "asset-card__chg",
          if (price_chg < 0) span(class = "delta-down", "▼ ", format_pct(abs(price_chg)))
          else if (price_chg > 0) span(class = "delta-up", "▲ ", format_pct(price_chg))
          else span(class = "delta-flat", "·")),
        div(class = "asset-card__metrics",
          span(class = "metric-key", "20D Vol"),
          span(class = "metric-val amber",
               if (is.finite(vol)) format_pct(vol) else "—"),
          span(class = "metric-key", "Max DD"),
          span(class = "metric-val red",
               if (is.finite(dd)) format_pct(dd) else "—"),
          span(class = "metric-key", "VaR 95%"),
          span(class = "metric-val amber",
               if (is.finite(var_1)) format_pct(var_1) else "—"),
          span(class = "metric-key", "Regime"),
          span(class = paste("metric-val", paste0("regime-", tier)),
               format_number(regime, accuracy = 0.01))
        ),
        div(class = "asset-card__regime-track",
          div(class = paste("asset-card__regime-fill", paste0("regime-", tier)),
              style = sprintf("width:%.0f%%;",
                              max(0, min(100, regime * 100))))
        )
      )
    })
    div(class = "asset-cards-grid", cards)
  })

  output$overview_knowledge <- renderUI({
    terms <- tryCatch(read_risk_terms(), error = function(e) data.frame())
    if (nrow(terms) == 0) return(p("No risk terms found."))
    lapply(seq_len(nrow(terms)), function(i)
      div(class = "knowledge-card",
        div(class = "knowledge-title", terms$term[[i]]),
        p(class = "knowledge-copy", terms$definition[[i]]),
        if (!is.null(terms$implication) && nzchar(terms$implication[[i]]))
          p(class = "knowledge-foot", terms$implication[[i]])
      ))
  })

  output$overview_playbook <- renderUI({
    lines <- tryCatch({
      raw <- read_playbook()
      ll  <- strsplit(raw, "\n", fixed = TRUE)[[1]]
      trimws(ll[nzchar(trimws(ll))])
    }, error = function(e) character(0))
    if (!length(lines)) return(p("Playbook not found."))
    lapply(lines, function(item) div(class = "playbook-line", item))
  })

  # ============================================================================
  # Quality Dashboard Server
  # ============================================================================
  qd_refresh_trigger <- reactiveVal(0)
  observeEvent(input$qd_refresh, qd_refresh_trigger(qd_refresh_trigger() + 1))

  qd_runs <- reactive({
    qd_refresh_trigger()
    cutoff <- qd_window_cutoff(input$qd_window)
    tryCatch(fetch_agent_runs(since = cutoff, limit = 5000L),
             error = function(e) data.frame())
  })

  qd_scores <- reactive({
    qd_refresh_trigger()
    cutoff <- qd_window_cutoff(input$qd_window)
    tryCatch(fetch_quality_scores(since = cutoff, limit = 5000L),
             error = function(e) data.frame())
  })

  # ----- KPIs -----
  output$qd_kpi_total <- renderUI({
    n <- nrow(qd_scores())
    div(class = "kpi-value", as.character(n))
  })
  output$qd_kpi_avg_score <- renderUI({
    s <- qd_scores()
    val <- if (nrow(s) > 0) mean(s$final_score, na.rm = TRUE) else NA_real_
    div(class = "kpi-value", format_number(val, 0.01))
  })
  output$qd_kpi_pass_rate <- renderUI({
    s <- qd_scores()
    val <- if (nrow(s) > 0) mean(s$passed, na.rm = TRUE) else NA_real_
    div(class = "kpi-value", format_pct(val, 1))
  })
  output$qd_kpi_avg_iter <- renderUI({
    s <- qd_scores()
    val <- if (nrow(s) > 0) mean(s$iterations_used, na.rm = TRUE) else NA_real_
    div(class = "kpi-value", format_number(val, 0.01))
  })
  output$qd_kpi_p95 <- renderUI({
    r <- qd_runs()
    val <- if (nrow(r) > 0) {
      stats::quantile(r$latency_ms, 0.95, na.rm = TRUE)
    } else NA_real_
    div(class = "kpi-value",
        if (is.finite(val)) sprintf("%d ms", as.integer(val)) else "NA")
  })
  output$qd_kpi_err <- renderUI({
    r <- qd_runs()
    val <- if (nrow(r) > 0) {
      mean(!is.na(r$error_class), na.rm = TRUE)
    } else NA_real_
    cls <- if (is.finite(val) && val > 0.05) "kpi-value warning" else "kpi-value"
    div(class = cls, format_pct(val, 1))
  })

  # ----- Time series -----
  output$qd_time_series <- renderPlotly({
    s <- qd_scores()
    if (nrow(s) == 0) {
      return(plotly::plot_ly() |> plotly::layout(
        annotations = list(list(text = "No data yet — click Simulate on an asset page",
          xref="paper",yref="paper",x=0.5,y=0.5,showarrow=FALSE,
          font=list(size=13, color="#7e8593"))),
        paper_bgcolor="rgba(0,0,0,0)"
      ) |> plotly::config(displayModeBar=FALSE))
    }
    s$ts <- as.POSIXct(s$created_at, tz = Sys.timezone())
    s$color <- ifelse(s$passed == 1L, "#a3ff12", "#ff5470")
    s$txt <- paste0(s$symbol, " — ",
                    substr(safe_chr_vec(s$headline), 1, 70))

    plotly::plot_ly(
      data = s, x = ~ts, y = ~final_score,
      type = "scatter", mode = "markers",
      marker = list(color = ~color, size = 10,
                    line = list(color = "#fff", width = 1)),
      text = ~txt,
      hovertemplate = "%{text}<br>Score: %{y:.2f}<br>%{x}<extra></extra>"
    ) |>
      plotly::layout(
        shapes = list(list(type = "line", x0 = min(s$ts), x1 = max(s$ts),
                           y0 = QUALITY_THRESHOLD, y1 = QUALITY_THRESHOLD,
                           line = list(color = "#7e8593", dash = "dash"))),
        yaxis = list(title = "Quality Score", range = c(0, 1)),
        xaxis = list(title = ""),
        paper_bgcolor = "rgba(0,0,0,0)",
        plot_bgcolor  = "rgba(0,0,0,0)",
        margin = list(l = 50, r = 20, t = 10, b = 30)
      ) |>
      apply_plotly_dark() |>
      plotly::config(displayModeBar = FALSE, displaylogo = FALSE)
  })

  # ----- Dimension breakdown -----
  output$qd_dimensions <- renderPlotly({
    s <- qd_scores()
    if (nrow(s) == 0) {
      return(plotly::plot_ly() |> plotly::layout(
        annotations = list(list(text = "No data yet",
          xref="paper",yref="paper",x=0.5,y=0.5,showarrow=FALSE)),
        paper_bgcolor="rgba(0,0,0,0)"
      ) |> plotly::config(displayModeBar=FALSE))
    }
    means <- c(
      Clarity        = mean(s$clarity,           na.rm = TRUE),
      Completeness   = mean(s$completeness,      na.rm = TRUE),
      Actionability  = mean(s$actionability,     na.rm = TRUE),
      `Factual Alignment` = mean(s$factual_alignment, na.rm = TRUE),
      Tone           = mean(s$tone,              na.rm = TRUE)
    )
    df <- data.frame(dim = names(means), val = as.numeric(means),
                     stringsAsFactors = FALSE)
    df$color <- ifelse(df$val >= 0.75, "#a3ff12",
                ifelse(df$val >= 0.5,  "#ffb84d", "#ff5470"))
    plotly::plot_ly(
      data = df, x = ~val, y = ~dim, type = "bar", orientation = "h",
      marker = list(color = ~color),
      text = ~format_number(val, 0.01), textposition = "outside",
      hovertemplate = "%{y}: %{x:.2f}<extra></extra>"
    ) |>
      plotly::layout(
        xaxis = list(title = "", range = c(0, 1)),
        yaxis = list(title = "", categoryorder = "array",
                     categoryarray = rev(df$dim)),
        paper_bgcolor = "rgba(0,0,0,0)",
        plot_bgcolor  = "rgba(0,0,0,0)",
        margin = list(l = 110, r = 30, t = 10, b = 30)
      ) |>
      apply_plotly_dark() |>
      plotly::config(displayModeBar = FALSE, displaylogo = FALSE)
  })

  # ----- Latency by agent -----
  output$qd_latency <- renderPlotly({
    r <- qd_runs()
    if (nrow(r) == 0) {
      return(plotly::plot_ly() |> plotly::layout(
        annotations = list(list(text = "No data yet",
          xref="paper",yref="paper",x=0.5,y=0.5,showarrow=FALSE)),
        paper_bgcolor="rgba(0,0,0,0)"
      ) |> plotly::config(displayModeBar=FALSE))
    }
    plotly::plot_ly(
      data = r, x = ~agent_name, y = ~latency_ms, type = "box",
      boxpoints = "outliers",
      marker = list(color = "#5b8def"),
      line   = list(color = "#7e8593")
    ) |>
      plotly::layout(
        xaxis = list(title = ""),
        yaxis = list(title = "ms"),
        paper_bgcolor = "rgba(0,0,0,0)",
        plot_bgcolor  = "rgba(0,0,0,0)",
        margin = list(l = 50, r = 20, t = 10, b = 40)
      ) |>
      apply_plotly_dark() |>
      plotly::config(displayModeBar = FALSE, displaylogo = FALSE)
  })

  # ----- Iteration distribution -----
  output$qd_iterations <- renderPlotly({
    s <- qd_scores()
    if (nrow(s) == 0) {
      return(plotly::plot_ly() |> plotly::layout(
        annotations = list(list(text = "No data yet",
          xref="paper",yref="paper",x=0.5,y=0.5,showarrow=FALSE)),
        paper_bgcolor="rgba(0,0,0,0)"
      ) |> plotly::config(displayModeBar=FALSE))
    }
    counts <- table(factor(s$iterations_used,
                           levels = seq_len(MAX_LOOP_ITERATIONS)))
    df <- data.frame(iter = paste0(names(counts), if_else_label(names(counts))),
                     n = as.integer(counts), stringsAsFactors = FALSE)
    df$color <- ifelse(df$iter == "1 iteration", "#a3ff12", "#ffb84d")

    plotly::plot_ly(
      data = df, x = ~iter, y = ~n, type = "bar",
      marker = list(color = ~color),
      text = ~as.character(n), textposition = "outside",
      hovertemplate = "%{x}: %{y} alerts<extra></extra>"
    ) |>
      plotly::layout(
        xaxis = list(title = ""),
        yaxis = list(title = "Alerts"),
        paper_bgcolor = "rgba(0,0,0,0)",
        plot_bgcolor  = "rgba(0,0,0,0)",
        margin = list(l = 50, r = 20, t = 10, b = 40)
      ) |>
      apply_plotly_dark() |>
      plotly::config(displayModeBar = FALSE, displaylogo = FALSE)
  })

  # ----- Error rate over time (rolling 1h) -----
  output$qd_errors <- renderPlotly({
    r <- qd_runs()
    if (nrow(r) == 0) {
      return(plotly::plot_ly() |> plotly::layout(
        annotations = list(list(text = "No data yet",
          xref="paper",yref="paper",x=0.5,y=0.5,showarrow=FALSE)),
        paper_bgcolor="rgba(0,0,0,0)"
      ) |> plotly::config(displayModeBar=FALSE))
    }
    r$ts  <- as.POSIXct(r$started_at, tz = Sys.timezone())
    r$err <- as.integer(!is.na(r$error_class))
    r <- r[order(r$ts), ]
    # rolling mean over 20 points (cheap proxy for 1h-ish window)
    win <- min(20L, nrow(r))
    r$rolling_err <- zoo::rollmean(r$err, k = win, fill = NA, align = "right")

    plotly::plot_ly(
      data = r, x = ~ts, y = ~rolling_err,
      type = "scatter", mode = "lines",
      line = list(color = "#ff5470", width = 2),
      hovertemplate = "Error rate: %{y:.1%}<br>%{x}<extra></extra>"
    ) |>
      plotly::layout(
        xaxis = list(title = ""),
        yaxis = list(title = "Error rate", tickformat = ".0%",
                     range = c(0, max(0.1, max(r$rolling_err, na.rm = TRUE) * 1.2))),
        paper_bgcolor = "rgba(0,0,0,0)",
        plot_bgcolor  = "rgba(0,0,0,0)",
        margin = list(l = 50, r = 20, t = 10, b = 30)
      ) |>
      apply_plotly_dark() |>
      plotly::config(displayModeBar = FALSE, displaylogo = FALSE)
  })

  # ----- Low-scoring memos table -----
  output$qd_low_scores <- renderDT({
    s <- qd_scores()
    if (nrow(s) == 0) {
      return(DT::datatable(
        data.frame(`No alerts yet` = character(), check.names = FALSE),
        options = list(dom = "t"), rownames = FALSE))
    }
    s <- s[order(s$final_score, na.last = TRUE), ]
    show <- utils::head(s, 10L)
    df <- data.frame(
      `Alert ID` = show$alert_id,
      `Time`     = show$created_at,
      Symbol     = show$symbol,
      Score      = format_number(show$final_score, 0.01),
      Passed     = ifelse(show$passed == 1L, "✓", "✗"),
      Iter       = show$iterations_used,
      Headline   = substr(safe_chr_vec(show$headline), 1, 80),
      check.names = FALSE, stringsAsFactors = FALSE
    )
    DT::datatable(df, rownames = FALSE, selection = "single",
      class = "compact stripe hover",
      options = list(pageLength = 10, dom = "tip", scrollX = TRUE))
  }, server = FALSE)

  # ============================================================================
  # Alert Log & Ops Server
  # ============================================================================
  ops_alerts <- reactivePoll(
    intervalMillis = 5000, session = session,
    checkFunc = function() {
      if (!file.exists(APP_DB_PATH)) return(0)
      as.numeric(file.info(APP_DB_PATH)$mtime)
    },
    valueFunc = function() fetch_alert_history(limit = 200L)
  )

  selected_alert_id <- reactiveVal(NULL)

  ops_filtered_data <- reactive({
    history <- ops_alerts()
    if (!nrow(history)) return(history)
    if (input$ops_asset_filter != "All")
      history <- history[history$symbol == input$ops_asset_filter, , drop = FALSE]
    if (input$ops_type_filter != "All")
      history <- history[history$event_type == input$ops_type_filter, , drop = FALSE]
    history
  })

  output$ops_alert_table <- renderDT({
    history <- ops_filtered_data()
    if (!nrow(history)) {
      history <- tibble::tibble(
        alert_id = integer(), received_at = character(), symbol = character(),
        event_type = character(), reference_type = character(),
        reference_level = character(), risk_level = character(),
        primary_driver = character(), headline = character()
      )
    }
    if ("reference_type" %in% names(history))
      history$reference_type <- vapply(history$reference_type, title_case,
                                       character(1))
    if ("reference_level" %in% names(history))
      history$reference_level <- vapply(history$reference_level, format_dollar,
                                        character(1), accuracy = 0.01)
    cols <- intersect(
      c("alert_id", "received_at", "symbol", "event_type",
        "reference_type", "reference_level",
        "risk_level", "primary_driver", "headline"),
      names(history)
    )
    DT::datatable(history[, cols, drop = FALSE], rownames = FALSE,
      selection = "single",
      class = "compact stripe hover",
      options = list(pageLength = 15, dom = "ltip", scrollX = TRUE))
  }, server = FALSE)

  observeEvent(input$ops_alert_table_rows_selected, {
    history <- ops_filtered_data()
    if (nrow(history) > 0 && !is.null(input$ops_alert_table_rows_selected)) {
      row_idx <- input$ops_alert_table_rows_selected
      if ("alert_id" %in% names(history))
        selected_alert_id(history$alert_id[[row_idx]])
    }
  })

  ops_detail <- reactive({
    aid <- selected_alert_id()
    if (is.null(aid)) return(NULL)
    fetch_analysis_by_id(aid)
  })

  output$ops_raw_payload <- renderText({
    d <- ops_detail()
    if (is.null(d)) return("Select a row above.")
    json_pretty(d$raw_payload %||% list())
  })
  output$ops_triage_json <- renderText({
    d <- ops_detail()
    if (is.null(d)) return("Select a row above.")
    json_pretty(d$triage %||% list())
  })
  output$ops_metrics_json <- renderText({
    d <- ops_detail()
    if (is.null(d)) return("Select a row above.")
    json_pretty(d$risk %||% list())
  })

  # Memo + Critic merged panel
  output$ops_memo_output <- renderUI({
    d <- ops_detail()
    if (is.null(d)) return(p("Select a row above."))

    q <- tryCatch(fetch_quality_score_for_alert(d$alert$alert_id),
                  error = function(e) NULL)

    tagList(
      div(class = "memo-headline", safe_chr(d$memo$headline, "")),
      tags$pre(class = "memo-body", safe_chr(d$memo$memo, "")),
      if (nzchar(safe_chr(d$memo$recommended_action, "")))
        div(class = "memo-action",
            strong("Next step: "), safe_chr(d$memo$recommended_action, "")),
      if (!is.null(q) && is.finite(safe_num(q$final_score, NA_real_))) {
        ds <- q$dimension_scores %||% list()
        div(class = "ops-critic-block",
          div(class = "section-label top-space", "Critic Verdict"),
          div(class = "qs-top",
            div(class = paste("qs-pill",
                              if (isTRUE(q$passed)) "qs-pass" else "qs-fail"),
                if (isTRUE(q$passed)) "PASSED" else "FAILED"),
            div(class = "qs-score",
              span(class = "qs-score-num", format_number(q$final_score, 0.01)),
              span(class = "qs-score-suffix", "/ 1.00")),
            div(class = "qs-iter",
              span(class = "qs-iter-num", as.character(q$iterations_used)),
              span(class = "qs-iter-label",
                   if ((q$iterations_used %||% 1L) > 1L) "iterations" else "iteration"))),
          div(class = "qs-dim-list",
            tags$small(
              sprintf("Clarity %.2f · Completeness %.2f · Actionability %.2f · Factual %.2f · Tone %.2f",
                      safe_num(ds$clarity, NA_real_),
                      safe_num(ds$completeness, NA_real_),
                      safe_num(ds$actionability, NA_real_),
                      safe_num(ds$factual_alignment, NA_real_),
                      safe_num(ds$tone, NA_real_))))
        )
      }
    )
  })

  output$ops_knowledge_viewer <- renderUI({
    d <- ops_detail()
    selected_symbol <- if (!is.null(d)) {
      safe_chr(d$alert$symbol, default = "")
    } else if (!is.null(input$ops_asset_filter) &&
               input$ops_asset_filter != "All") {
      input$ops_asset_filter
    } else {
      ""
    }

    cases <- tryCatch({
      if (nzchar(selected_symbol)) {
        find_asset_historical_cases(selected_symbol, limit = 4L)
      } else {
        head(sort_historical_cases(read_historical_cases()), 4L)
      }
    }, error = function(e) data.frame())

    render_historical_case_cards(
      cases,
      empty_message = if (nzchar(selected_symbol)) {
        paste("No historical cases found for", selected_symbol, ".")
      } else {
        "No historical cases found."
      }
    )
  })

  output$ops_system_status <- renderUI({
    db_ok  <- file.exists(APP_DB_PATH)
    kb_ok  <- file.exists(PLAYBOOK_PATH)
    ai_ok  <- nzchar(openai_key())
    n_alrt <- if (db_ok) nrow(ops_alerts()) else 0L
    cache  <- llm_cache_stats()

    tagList(
      div(class = "status-row",
        div(class = paste0("status-dot ", if (db_ok) "green" else "red")),
        span("SQLite DB: ", if (db_ok) "Connected" else "Not found"),
        span(class = "status-detail", APP_DB_PATH)),
      div(class = "status-row",
        div(class = paste0("status-dot ", if (kb_ok) "green" else "red")),
        span("Knowledge Base: ", if (kb_ok) "Loaded" else "Not found")),
      div(class = "status-row",
        div(class = paste0("status-dot ", if (ai_ok) "green" else "red")),
        span("OpenAI API: ",
          if (ai_ok) paste("Key set —", OPENAI_MODEL)
          else "NOT configured — add OPENAI_API_KEY to .env")),
      div(class = "status-row",
        div(class = "status-dot green"),
        span("Yahoo Finance: Real-time data via quantmod")),
      div(class = "status-row",
        div(class = "status-dot green"),
        span("Total Alerts: ", n_alrt)),
      div(class = "status-row",
        div(class = "status-dot green"),
        span("Assets: ", paste(APP_ASSETS$label, collapse = ", "))),
      div(class = "status-row",
        div(class = "status-dot green"),
        span("LLM Cache: ", cache$entries, " entries  ·  ",
             "hits ", cache$hits, " / misses ", cache$misses))
    )
  })

  # ----- Agent runs telemetry table on Ops page -----
  output$ops_agent_runs <- renderDT({
    aid <- selected_alert_id()
    if (is.null(aid)) {
      return(DT::datatable(
        data.frame(`Select a row above` = character(), check.names = FALSE),
        options = list(dom = "t"), rownames = FALSE))
    }
    conn <- db_connect()
    on.exit(DBI::dbDisconnect(conn), add = TRUE)
    rows <- DBI::dbGetQuery(conn, sprintf(
      "SELECT agent_name, iteration, latency_ms, prompt_tokens,
              completion_tokens, n_retries, cache_hit, validation_passed,
              error_class
       FROM agent_runs WHERE alert_id = %d
       ORDER BY id ASC;",
      as.integer(aid)))
    if (!nrow(rows)) {
      return(DT::datatable(
        data.frame(`No telemetry rows for this alert` = character(),
                   check.names = FALSE),
        options = list(dom = "t"), rownames = FALSE))
    }
    DT::datatable(rows, rownames = FALSE,
      class = "compact stripe hover",
      options = list(pageLength = 8, dom = "t", scrollX = TRUE))
  }, server = FALSE)

  # Suspend non-active page outputs when their tabPanelBody is hidden.
  # Cuts main-thread work + RAM by avoiding initial-render of every tab's
  # plotly / DT / cross-asset Yahoo fetches when user is on a different page.
  for (oid in c(
        # Risk Overview
        "overview_risk_table", "overview_asset_cards",
        "overview_knowledge", "overview_playbook",
        # Quality Dashboard
        "qd_kpi_total", "qd_kpi_avg_score", "qd_kpi_pass_rate",
        "qd_kpi_avg_iter", "qd_kpi_p95", "qd_kpi_err",
        "qd_time_series", "qd_dimensions", "qd_latency",
        "qd_iterations", "qd_errors", "qd_low_scores",
        # Alert Log / Ops
        "ops_alert_table", "ops_raw_payload", "ops_triage_json",
        "ops_metrics_json", "ops_memo_output", "ops_knowledge_viewer",
        "ops_system_status", "ops_agent_runs"
      )) {
    outputOptions(output, oid, suspendWhenHidden = TRUE)
  }
}

# Helper used in qd_iterations
if_else_label <- function(s) {
  ifelse(s == "1", " iteration", " iterations")
}

# Vectorized safe_chr
safe_chr_vec <- function(x) {
  if (is.null(x) || length(x) == 0) return(character(0))
  out <- as.character(x)
  out[is.na(out)] <- ""
  out
}
