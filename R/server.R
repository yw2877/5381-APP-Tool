app_server <- function(input, output, session) {

  # ---------- reactives ----------
  selected_lookback <- reactive({
    as.integer(input$lookback %||% DEFAULT_LOOKBACK)
  })

  current_asset <- reactive({
    asset_row(input$asset)
  })

  alerts_data <- reactivePoll(
    intervalMillis = 2500,
    session = session,
    checkFunc = function() {
      if (!file.exists(APP_DB_PATH)) return(0)
      as.numeric(file.info(APP_DB_PATH)$mtime)
    },
    valueFunc = function() {
      fetch_alert_history(limit = 100L)
    }
  )

  # Main analysis — invalidates on asset/lookback change or refresh
  refresh_trigger <- reactiveVal(0)

  observeEvent(input$refresh_btn, {
    refresh_trigger(refresh_trigger() + 1)
  })

  active_analysis <- reactive({
    input$asset
    selected_lookback()
    refresh_trigger()

    stored <- fetch_latest_analysis(symbol = input$asset)
    if (!is.null(stored) && !is.null(stored$risk) && !is.null(stored$triage)) {
      return(stored)
    }

    run_agent_pipeline(
      alert = baseline_alert(input$asset),
      lookback = selected_lookback()
    )
  })

  # ---------- Simulate Alert ----------
  observeEvent(input$simulate_alert, {
    payload <- build_simulated_alert(input$asset)
    result <- process_and_store_alert(payload, lookback = selected_lookback())
    showNotification(
      glue("Stored simulated alert #{result$alert_id} for {input$asset}."),
      type = "message"
    )
  })

  # ========== PAGE 1: Dashboard ==========

  # Risk badge
  output$risk_badge <- renderUI({
    level <- active_analysis()$risk$risk_level %||% "monitor"
    div(
      class = paste("risk-pill", risk_badge_class(level)),
      toupper(safe_chr(level, default = "monitor"))
    )
  })

  # KPI boxes
  output$kpi_price <- renderUI({
    div(class = "kpi-value", format_dollar(active_analysis()$risk$latest_price, accuracy = 0.01))
  })
  output$kpi_vol <- renderUI({
    div(class = "kpi-value", format_pct(active_analysis()$risk$rolling_vol_20d))
  })
  output$kpi_dd <- renderUI({
    div(class = "kpi-value warning", format_pct(active_analysis()$risk$max_drawdown))
  })
  output$kpi_var <- renderUI({
    div(class = "kpi-value", format_pct(active_analysis()$risk$var_1d))
  })
  output$kpi_regime <- renderUI({
    score <- active_analysis()$risk$regime_score
    cls <- if (safe_num(score, 0) >= 0.6) "kpi-value warning" else "kpi-value"
    div(class = cls, format_number(score, accuracy = 0.01))
  })
  output$kpi_last_alert <- renderUI({
    ts <- active_analysis()$alert$received_at
    div(class = "kpi-value small", format_ts(ts))
  })

  # TradingView chart
  output$tv_chart <- renderUI({
    asset <- current_asset()
    tv_widget_html(asset$tv_symbol[[1]])
  })

  # Triage panel
  output$triage_panel <- renderUI({
    triage <- active_analysis()$triage
    latest <- active_analysis()$alert
    tagList(
      div(class = "agent-title", title_case(triage$signal_type)),
      p(class = "agent-copy", safe_chr(triage$rationale, default = "")),
      div(class = "inline-meta", strong("Event:"), safe_chr(latest$event_type, default = "baseline_check")),
      div(class = "inline-meta", strong("Severity Hint:"), toupper(safe_chr(triage$severity_hint, default = "medium"))),
      div(
        class = "focus-list",
        lapply(triage$suggested_focus, function(item) {
          div(class = "focus-chip", safe_chr(item, default = "watch"))
        })
      )
    )
  })

  # Risk metrics panel
  output$risk_metrics_panel <- renderUI({
    risk <- active_analysis()$risk
    div(
      class = "metric-grid",
      metric_box("Latest Price", format_dollar(risk$latest_price, accuracy = 0.01)),
      metric_box("20D Vol", format_pct(risk$rolling_vol_20d)),
      metric_box("Max Drawdown", format_pct(risk$max_drawdown)),
      metric_box("1D VaR", format_pct(risk$var_1d)),
      metric_box("1D ES", format_pct(risk$es_1d)),
      metric_box("Corr Jump", format_number(risk$correlation_jump, accuracy = 0.01)),
      metric_box("Regime Score", format_number(risk$regime_score, accuracy = 0.01)),
      metric_box("Primary Driver", title_case(risk$primary_driver))
    )
  })

  # Memo panel
  output$memo_panel <- renderUI({
    memo <- active_analysis()$memo
    tagList(
      div(class = "memo-headline", safe_chr(memo$headline, default = "No memo available")),
      tags$pre(class = "memo-body", safe_chr(memo$memo, default = "No memo available")),
      if (!is.null(memo$recommended_action) && nzchar(safe_chr(memo$recommended_action, ""))) {
        div(class = "memo-action", strong("Next step: "), memo$recommended_action)
      }
    )
  })

  # Alert feed table
  output$alert_history <- renderDT({
    history <- alerts_data()
    if (!nrow(history)) {
      history <- tibble::tibble(
        received_at = character(), symbol = character(),
        event_type = character(), risk_level = character(),
        primary_driver = character(), trigger_price = numeric(),
        source = character()
      )
    }
    cols <- intersect(c("received_at", "symbol", "event_type", "risk_level", "primary_driver", "trigger_price", "source"), names(history))
    DT::datatable(
      history[, cols],
      rownames = FALSE,
      class = "compact stripe hover",
      options = list(pageLength = 8, dom = "tip", ordering = FALSE)
    )
  }, server = FALSE)

  # Knowledge panel
  output$knowledge_panel <- renderUI({
    knowledge <- active_analysis()$knowledge
    terms_ui <- lapply(knowledge$terms, function(item) {
      div(class = "knowledge-card",
        div(class = "knowledge-title", safe_chr(item$term[[1]], default = "Concept")),
        p(class = "knowledge-copy", safe_chr(item$definition[[1]], default = "")),
        p(class = "knowledge-foot", safe_chr(item$implication[[1]], default = ""))
      )
    })
    cases_ui <- lapply(knowledge$cases, function(item) {
      div(class = "knowledge-card muted",
        div(class = "knowledge-title", safe_chr(item$case_name[[1]], default = "Case")),
        p(class = "knowledge-copy", safe_chr(item$summary[[1]], default = "")),
        p(class = "knowledge-foot", safe_chr(item$watch_items[[1]], default = ""))
      )
    })
    playbook_ui <- lapply(knowledge$playbook, function(item) {
      div(class = "playbook-line", safe_chr(item, default = ""))
    })
    tagList(
      div(class = "section-label", "Risk Terms"), terms_ui,
      div(class = "section-label top-space", "Similar Cases"), cases_ui,
      div(class = "section-label top-space", "Playbook"), playbook_ui
    )
  })

  # ========== PAGE 2: Alert Log & Operations ==========

  # Selected alert for detail view
  selected_alert_id <- reactiveVal(NULL)

  # Filtered alert table
  ops_filtered_data <- reactive({
    history <- alerts_data()
    if (!nrow(history)) return(history)

    if (input$ops_asset_filter != "All") {
      history <- history[history$symbol == input$ops_asset_filter, , drop = FALSE]
    }
    if (input$ops_type_filter != "All") {
      history <- history[history$event_type == input$ops_type_filter, , drop = FALSE]
    }
    history
  })

  output$ops_alert_table <- renderDT({
    history <- ops_filtered_data()
    if (!nrow(history)) {
      history <- tibble::tibble(
        alert_id = integer(), received_at = character(), symbol = character(),
        event_type = character(), risk_level = character(),
        primary_driver = character(), headline = character()
      )
    }
    cols <- intersect(c("alert_id", "received_at", "symbol", "event_type", "risk_level", "primary_driver", "headline"), names(history))
    DT::datatable(
      history[, cols],
      rownames = FALSE,
      selection = "single",
      class = "compact stripe hover",
      options = list(pageLength = 15, dom = "ltip")
    )
  }, server = FALSE)

  # When user clicks a row, fetch detail
  observeEvent(input$ops_alert_table_rows_selected, {
    history <- ops_filtered_data()
    if (nrow(history) > 0 && !is.null(input$ops_alert_table_rows_selected)) {
      row_idx <- input$ops_alert_table_rows_selected
      if ("alert_id" %in% names(history)) {
        selected_alert_id(history$alert_id[[row_idx]])
      }
    }
  })

  ops_detail <- reactive({
    aid <- selected_alert_id()
    if (is.null(aid)) return(NULL)
    fetch_analysis_by_id(aid)
  })

  output$ops_raw_payload <- renderText({
    detail <- ops_detail()
    if (is.null(detail)) return("Select a row from the alert table above.")
    json_pretty(detail$raw_payload %||% list())
  })

  output$ops_triage_json <- renderText({
    detail <- ops_detail()
    if (is.null(detail)) return("Select a row from the alert table above.")
    json_pretty(detail$triage %||% list())
  })

  output$ops_metrics_json <- renderText({
    detail <- ops_detail()
    if (is.null(detail)) return("Select a row from the alert table above.")
    json_pretty(detail$risk %||% list())
  })

  output$ops_memo_output <- renderUI({
    detail <- ops_detail()
    if (is.null(detail)) return(p("Select a row from the alert table above."))
    tagList(
      div(class = "memo-headline", safe_chr(detail$memo$headline, "")),
      tags$pre(class = "memo-body", safe_chr(detail$memo$memo, ""))
    )
  })

  # Knowledge base viewer
  output$ops_knowledge_viewer <- renderUI({
    terms <- tryCatch(read_risk_terms(), error = function(e) data.frame())
    cases <- tryCatch(read_historical_cases(), error = function(e) data.frame())

    tagList(
      h5("Risk Terms"),
      if (nrow(terms) > 0) {
        lapply(seq_len(nrow(terms)), function(i) {
          div(class = "knowledge-card",
            div(class = "knowledge-title", terms$term[[i]]),
            p(class = "knowledge-copy", terms$definition[[i]])
          )
        })
      } else {
        p("No risk terms found.")
      },
      h5(class = "mt-3", "Historical Cases"),
      if (nrow(cases) > 0) {
        lapply(seq_len(nrow(cases)), function(i) {
          div(class = "knowledge-card muted",
            div(class = "knowledge-title", cases$case_name[[i]]),
            p(class = "knowledge-copy", cases$summary[[i]]),
            p(class = "knowledge-foot", paste("Watch:", cases$watch_items[[i]]))
          )
        })
      } else {
        p("No cases found.")
      }
    )
  })

  # System status
  output$ops_system_status <- renderUI({
    db_exists <- file.exists(APP_DB_PATH)
    kb_exists <- file.exists(PLAYBOOK_PATH)
    openai_ok <- nzchar(OPENAI_API_KEY)
    n_alerts <- if (db_exists) nrow(alerts_data()) else 0L

    tagList(
      div(class = "status-row",
        div(class = paste0("status-dot ", if (db_exists) "green" else "red")),
        span("SQLite Database: ", if (db_exists) "Connected" else "Not found"),
        span(class = "status-detail", APP_DB_PATH)
      ),
      div(class = "status-row",
        div(class = paste0("status-dot ", if (kb_exists) "green" else "red")),
        span("Knowledge Base: ", if (kb_exists) "Loaded" else "Not found")
      ),
      div(class = "status-row",
        div(class = paste0("status-dot ", if (openai_ok) "green" else "yellow")),
        span("OpenAI API: ", if (openai_ok) "Connected" else "Not configured (using fallback)")
      ),
      div(class = "status-row",
        div(class = "status-dot green"),
        span("Total Alerts: ", n_alerts)
      ),
      div(class = "status-row",
        div(class = "status-dot green"),
        span("Model: ", OPENAI_MODEL)
      ),
      div(class = "status-row",
        div(class = "status-dot green"),
        span("Assets: ", paste(APP_ASSETS$label, collapse = ", "))
      )
    )
  })
}
