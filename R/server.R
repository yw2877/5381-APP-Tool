app_server <- function(input, output, session) {
  selected_lookback <- reactive({
    as.integer(input$lookback %||% DEFAULT_LOOKBACK)
  })

  alerts_data <- reactivePoll(
    intervalMillis = 2500,
    session = session,
    checkFunc = function() {
      if (!file.exists(APP_DB_PATH)) {
        return(0)
      }
      as.numeric(file.info(APP_DB_PATH)$mtime)
    },
    valueFunc = function() {
      fetch_alert_history(limit = 50L)
    }
  )

  active_analysis <- reactive({
    stored <- fetch_latest_analysis(symbol = input$asset)
    if (!is.null(stored) && !is.null(stored$risk) && !is.null(stored$triage)) {
      return(stored)
    }

    run_agent_pipeline(
      alert = baseline_alert(input$asset),
      lookback = selected_lookback()
    )
  })

  observeEvent(input$simulate_alert, {
    payload <- build_simulated_alert(input$asset)
    result <- process_and_store_alert(payload, lookback = selected_lookback())

    showNotification(
      glue("Stored simulated alert #{result$alert_id} for {input$asset}."),
      type = "message"
    )
  })

  output$risk_badge <- renderUI({
    level <- active_analysis()$risk$risk_level %||% "monitor"
    div(
      class = paste("risk-pill", risk_badge_class(level)),
      toupper(safe_chr(level, default = "monitor"))
    )
  })

  output$fallback_price_plot <- renderPlot({
    prices <- get_price_history(input$asset, selected_lookback())
    op <- par(mar = c(3, 4, 2, 1))
    on.exit(par(op), add = TRUE)

    plot(
      prices$date,
      prices$close,
      type = "l",
      lwd = 2.6,
      col = "#0F5067",
      xlab = "",
      ylab = "Price",
      main = safe_chr(input$asset, default = "SPY")
    )
    grid(col = grDevices::adjustcolor("#94A3B8", alpha.f = 0.35))
    points(utils::tail(prices$date, 1), utils::tail(prices$close, 1), pch = 19, col = "#A55B28")
  })

  output$tv_slot <- renderUI({
    current_asset <- asset_row(input$asset)
    widget_cfg <- list(
      symbol = current_asset$tv_symbol[[1]],
      interval = "60",
      timezone = "America/New_York",
      theme = "light",
      studies = c("BB@tv-basicstudies", "ATR@tv-basicstudies")
    )

    div(
      class = "tv-slot",
      div(class = "tv-slot-title", "TradingView integration slot"),
      p(
        class = "tv-slot-copy",
        "Replace this block with your TradingView Advanced Chart iframe/widget and point alerts to the plumber endpoint."
      ),
      tags$pre(class = "json-trace compact", json_pretty(widget_cfg))
    )
  })

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

  output$triage_json <- renderText({
    json_pretty(active_analysis()$triage)
  })

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

  output$memo_panel <- renderUI({
    memo <- active_analysis()$memo
    tagList(
      div(class = "memo-headline", safe_chr(memo$headline, default = "No memo available")),
      tags$pre(class = "memo-body", safe_chr(memo$memo, default = "No memo available"))
    )
  })

  output$alert_history <- renderDT({
    history <- alerts_data()
    if (!nrow(history)) {
      history <- tibble::tibble(
        received_at = character(),
        symbol = character(),
        event_type = character(),
        risk_level = character(),
        primary_driver = character(),
        trigger_price = numeric(),
        source = character()
      )
    }

    DT::datatable(
      history[, c("received_at", "symbol", "event_type", "risk_level", "primary_driver", "trigger_price", "source")],
      rownames = FALSE,
      class = "compact stripe hover",
      options = list(pageLength = 8, dom = "tip", ordering = FALSE)
    )
  }, server = FALSE)

  output$knowledge_panel <- renderUI({
    knowledge <- active_analysis()$knowledge

    terms_ui <- lapply(knowledge$terms, function(item) {
      div(
        class = "knowledge-card",
        div(class = "knowledge-title", safe_chr(item$term[[1]], default = "Concept")),
        p(class = "knowledge-copy", safe_chr(item$definition[[1]], default = "")),
        p(class = "knowledge-foot", safe_chr(item$implication[[1]], default = ""))
      )
    })

    cases_ui <- lapply(knowledge$cases, function(item) {
      div(
        class = "knowledge-card muted",
        div(class = "knowledge-title", safe_chr(item$case_name[[1]], default = "Case")),
        p(class = "knowledge-copy", safe_chr(item$summary[[1]], default = "")),
        p(class = "knowledge-foot", safe_chr(item$watch_items[[1]], default = ""))
      )
    })

    playbook_ui <- lapply(knowledge$playbook, function(item) {
      div(class = "playbook-line", safe_chr(item, default = ""))
    })

    tagList(
      div(class = "section-label", "Risk Terms"),
      terms_ui,
      div(class = "section-label top-space", "Similar Cases"),
      cases_ui,
      div(class = "section-label top-space", "Playbook"),
      playbook_ui
    )
  })
}
