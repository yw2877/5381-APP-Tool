# ========== Helper: build a safe "no-data" risk object ==========

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

  if ("case_date" %in% names(case_row)) {
    case_date <- safe_chr(case_row$case_date[[1]], default = "")
    if (nzchar(case_date)) parts <- c(parts, case_date)
  }
  if ("asset_focus" %in% names(case_row)) {
    asset_focus <- safe_chr(case_row$asset_focus[[1]], default = "")
    if (nzchar(asset_focus)) parts <- c(parts, asset_focus)
  }
  if ("market_regime" %in% names(case_row)) {
    market_regime <- safe_chr(case_row$market_regime[[1]], default = "")
    if (nzchar(market_regime)) parts <- c(parts, market_regime)
  }
  if ("event_type" %in% names(case_row)) {
    event_type <- safe_chr(case_row$event_type[[1]], default = "")
    if (nzchar(event_type)) parts <- c(parts, title_case(event_type))
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
      div(class = "knowledge-title", safe_chr(case_row$case_name[[1]], default = "Untitled case")),
      p(class = "knowledge-copy", safe_chr(case_row$summary[[1]], default = "")),
      if ("watch_items" %in% names(case_row) &&
          nzchar(safe_chr(case_row$watch_items[[1]], default = ""))) {
        p(class = "knowledge-foot",
          paste("Watch:", safe_chr(case_row$watch_items[[1]], default = "")))
      }
    )
  })
}

# ========== Asset Dashboard Module Server ==========

assetDashboardServer <- function(id) {
  moduleServer(id, function(input, output, session) {

    selected_lookback <- reactive(as.integer(input$lookback %||% DEFAULT_LOOKBACK))
    current_asset     <- reactive(asset_row(input$asset))

    alerts_data <- reactivePoll(
      intervalMillis = 2500,
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
    # Independent of OpenAI.  Always shows real numbers or a clear error.
    market_risk <- reactive({
      req(input$asset)
      input$asset; selected_lookback(); refresh_trigger()
      tryCatch(
        compute_risk_metrics(input$asset, lookback = selected_lookback()),
        error = function(e) empty_risk(input$asset, conditionMessage(e))
      )
    })

    price_history <- reactive({
      req(input$asset)
      input$asset; selected_lookback(); refresh_trigger()
      tryCatch(
        get_price_history(input$asset, lookback = selected_lookback()),
        error = function(e) NULL
      )
    })

    # ── Reactive 2: OpenAI agent analysis ──────────────────────────────────
    # Returns a list with $error / $triage / $memo / $knowledge.
    # Never throws — always returns a safe value so outputs never crash.
    latest_stored_analysis <- reactive({
      req(input$asset)
      input$asset; alerts_data(); refresh_trigger()
      tryCatch(
        fetch_latest_analysis(symbol = input$asset),
        error = function(e) NULL
      )
    })

    ai_analysis <- reactive({
      req(input$asset)
      input$asset; selected_lookback(); refresh_trigger()

      stored <- latest_stored_analysis()
      if (!is.null(stored) && !is.null(stored$triage) && !is.null(stored$memo)) {
        return(list(
          error           = FALSE,
          api_key_missing = FALSE,
          source          = "stored",
          message         = NULL,
          alert           = stored$alert,
          triage          = stored$triage,
          memo            = stored$memo,
          knowledge       = stored$knowledge,
          risk            = stored$risk
        ))
      }

      if (!nzchar(openai_key())) {
        return(list(
          error           = TRUE,
          api_key_missing = TRUE,
          source          = "empty",
          message         = "No stored alert analysis is available for this asset. Add OPENAI_API_KEY=sk-... to your .env file and restart the app, then simulate again.",
          alert           = NULL,
          triage          = NULL,
          memo            = NULL,
          knowledge       = NULL,
          risk            = NULL
        ))
      }

      mkt <- market_risk()
      alert <- baseline_alert(input$asset)

      tryCatch({
        triage    <- signal_triage_agent(alert)
        knowledge <- retrieve_knowledge(
          signal_type = triage$signal_type,
          symbol      = input$asset,
          risk_level  = mkt$risk_level %||% "medium"
        )
        memo <- risk_memo_agent(alert, triage, mkt, knowledge)
        list(
          error           = FALSE,
          api_key_missing = FALSE,
          source          = "baseline",
          message         = NULL,
          alert           = alert,
          triage          = triage,
          memo            = memo,
          knowledge       = knowledge,
          risk            = mkt
        )
      }, error = function(e) {
        list(
          error           = TRUE,
          api_key_missing = FALSE,
          source          = "baseline_error",
          message         = conditionMessage(e),
          alert           = alert,
          triage          = NULL,
          memo            = NULL,
          knowledge       = NULL,
          risk            = mkt
        )
      })
    })

    # ── Simulate Alert ──────────────────────────────────────────────────────
    observeEvent(input$simulate_alert, {
      if (!nzchar(openai_key())) {
        showNotification(
          "Add OPENAI_API_KEY to your .env file and restart the app.",
          type = "error", duration = 6
        )
        return()
      }
      tryCatch({
        payload <- build_simulated_alert(
          input$asset,
          lookback = selected_lookback(),
          event_type = input$scenario
        )
        result  <- process_and_store_alert(payload, lookback = selected_lookback())
        refresh_trigger(refresh_trigger() + 1)
        showNotification(
          glue("Stored alert #{result$alert_id} for {input$asset}."),
          type = "message"
        )
      }, error = function(e) {
        showNotification(
          paste("Simulation error:", conditionMessage(e)),
          type = "error", duration = 10
        )
      })
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

      if (length(banners) == 0) return(NULL)
      do.call(tagList, banners)
    })

    # ── Risk badge (market data) ────────────────────────────────────────────
    output$risk_badge <- renderUI({
      level <- market_risk()$risk_level %||% "monitor"
      div(class = paste("risk-pill", risk_badge_class(level)),
          toupper(safe_chr(level, default = "monitor")))
    })

    # ── KPI boxes (market data — no OpenAI needed) ─────────────────────────
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
        if (!is.null(latest) && !is.null(latest$alert)) format_ts(latest$alert$received_at) else "No alerts yet"
      )
    })

    # ── TradingView chart (iframe embed — no JS, no race condition) ────────
    output$tv_chart <- renderUI({
      tv_widget_html(tv_symbol = current_asset()$tv_symbol[[1]])
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
        list(label = "Event Type", value = title_case(alert$event_type)),
        list(label = "Signal Type", value = title_case(triage$signal_type)),
        list(label = "Trigger Price", value = format_dollar(alert$trigger_price, accuracy = 0.01)),
        list(
          label = "Reference",
          value = if (nzchar(safe_chr(alert$reference_type, default = ""))) {
            paste0(
              title_case(alert$reference_type),
              " @ ",
              format_dollar(alert$reference_level, accuracy = 0.01)
            )
          } else {
            "N/A"
          }
        ),
        list(label = "Severity", value = toupper(safe_chr(triage$severity_hint, default = "medium"))),
        list(label = "Received", value = format_ts(alert$received_at))
      )
      tagList(
        div(
          class = "triage-summary-grid",
          lapply(summary_items, function(item) {
            div(
              class = "triage-summary-box",
              div(class = "triage-summary-label", item$label),
              div(class = "triage-summary-value", item$value)
            )
          })
        ),
        div(class = "agent-title", title_case(triage$signal_type)),
        p(class = "agent-copy", safe_chr(triage$rationale, default = "")),
        div(class = "inline-meta",
            strong("Event:"), safe_chr(alert$event_type, default = "baseline_check")),
        div(class = "inline-meta",
            strong("Severity:"),
            toupper(safe_chr(triage$severity_hint, default = "medium"))),
        div(class = "focus-list",
          lapply(triage$suggested_focus, function(item)
            div(class = "focus-chip", safe_chr(item, default = "watch")))
        )
      )
    })

    # ── Risk Engine Agent panel (market data only) ─────────────────────────
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

    # ── Plotly: Price + Rolling Volatility (market data) ───────────────────
    output$price_vol_chart <- renderPlotly({
      ph <- price_history()
      if (is.null(ph)) {
        return(plotly::plot_ly() |> plotly::layout(
          annotations = list(list(
            text = "Price data unavailable", xref = "paper", yref = "paper",
            x = 0.5, y = 0.5, showarrow = FALSE,
            font = list(size = 13, color = "#B31B1B")
          )),
          paper_bgcolor = "rgba(0,0,0,0)"
        ) |> plotly::config(displayModeBar = FALSE, displaylogo = FALSE))
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
        line = list(color = "#B31B1B", width = 2)
      ) |> plotly::layout(yaxis = list(title = "Price"))

      p2 <- plotly::plot_ly(
        prices, x = ~date, y = ~vol20,
        type = "scatter", mode = "lines", name = "20D Vol",
        line = list(color = "#2d2d2d", width = 1.5)
      ) |> plotly::layout(yaxis = list(title = "Ann. Vol", tickformat = ".0%"))

      plotly::subplot(p1, p2, nrows = 2, shareX = TRUE,
        heights = c(0.65, 0.35), titleY = TRUE) |>
        plotly::layout(
          paper_bgcolor = "rgba(0,0,0,0)",
          plot_bgcolor  = "rgba(255,255,255,0.8)",
          legend = list(orientation = "h", y = -0.05),
          margin = list(l = 50, r = 20, t = 10, b = 30),
          autosize = TRUE
        ) |>
        plotly::config(displayModeBar = FALSE, displaylogo = FALSE, responsive = TRUE)
    })

    # ── Plotly: Risk Metrics Bar (market data) ─────────────────────────────
    output$risk_bar_chart <- renderPlotly({
      risk <- market_risk()
      vals <- c(
        abs(safe_num(risk$rolling_vol_20d, 0)),
        abs(safe_num(risk$max_drawdown,    0)),
        abs(safe_num(risk$var_1d,          0)),
        abs(safe_num(risk$es_1d,           0)),
        safe_num(risk$regime_score,        0)
      )
      labels     <- c("20D Vol", "Max DD", "VaR 1D", "ES 1D", "Regime")
      thresholds <- c(0.40, 0.20, 0.04, 0.06, 0.70)
      bar_colors <- ifelse(vals >= thresholds, "#B31B1B",
                     ifelse(vals >= thresholds * 0.6, "#e67e22", "#2d6a2d"))

      plotly::plot_ly(
        x = labels, y = vals, type = "bar",
        marker        = list(color = bar_colors),
        text          = scales::percent(vals, accuracy = 0.1),
        textposition  = "outside",
        hovertemplate = "%{x}: %{text}<extra></extra>"
      ) |>
        plotly::layout(
          yaxis = list(title = "", tickformat = ".0%",
                       range = c(0, max(vals, na.rm = TRUE) * 1.35)),
          xaxis         = list(title = ""),
          paper_bgcolor = "rgba(0,0,0,0)",
          plot_bgcolor  = "rgba(255,255,255,0.8)",
          margin = list(l = 40, r = 20, t = 10, b = 30)
        ) |>
        plotly::config(displayModeBar = FALSE, displaylogo = FALSE)
    })

    # ── Alert feed ─────────────────────────────────────────────────────────
    output$alert_history <- renderDT({
      history <- alerts_data()
      if (nrow(history) > 0 && "symbol" %in% names(history))
        history <- history[history$symbol == input$asset, , drop = FALSE]

      if (!nrow(history)) {
        history <- tibble::tibble(
          received_at    = character(), symbol = character(),
          event_type     = character(), reference_type = character(),
          reference_level = character(), risk_level = character(),
          primary_driver = character(), trigger_price = character()
        )
      }
      if ("reference_type" %in% names(history))
        history$reference_type <- vapply(history$reference_type, title_case, character(1))
      if ("reference_level" %in% names(history))
        history$reference_level <- vapply(history$reference_level, format_dollar, character(1), accuracy = 0.01)
      if ("trigger_price" %in% names(history))
        history$trigger_price <- vapply(history$trigger_price, format_dollar, character(1), accuracy = 0.01)
      cols <- intersect(
        c("received_at", "symbol", "event_type",
          "reference_type", "reference_level",
          "risk_level", "primary_driver", "trigger_price"),
        names(history)
      )
      DT::datatable(history[, cols], rownames = FALSE,
        class   = "compact stripe hover",
        options = list(pageLength = 5, dom = "tip", ordering = FALSE, scrollX = TRUE))
    }, server = FALSE)

  }) # end moduleServer
}

# ========== App Server ==========

app_server <- function(input, output, session) {

  assetDashboardServer("crypto")
  assetDashboardServer("equity")

  # ── Risk Overview ──────────────────────────────────────────────────────

  output$overview_risk_table <- renderDT({
    rows <- lapply(APP_ASSETS$label, function(sym) {
      tryCatch({
        m <- compute_risk_metrics(sym, lookback = 120L)
        data.frame(
          Symbol        = sym,
          `Asset Class` = APP_ASSETS$asset_class[APP_ASSETS$label == sym],
          Price         = format_dollar(m$latest_price, accuracy = 0.01),
          `20D Vol`     = format_pct(m$rolling_vol_20d),
          `Max DD`      = format_pct(m$max_drawdown),
          `VaR 1D`      = format_pct(m$var_1d),
          `ES 1D`       = format_pct(m$es_1d),
          `Regime`      = format_number(m$regime_score, accuracy = 0.01),
          `Risk Level`  = toupper(m$risk_level),
          `Driver`      = title_case(m$primary_driver),
          check.names = FALSE, stringsAsFactors = FALSE
        )
      }, error = function(e) {
        data.frame(
          Symbol = sym, `Asset Class` = "N/A",
          Price = "ERR", `20D Vol` = "ERR", `Max DD` = "ERR",
          `VaR 1D` = "ERR", `ES 1D` = "ERR", Regime = "ERR",
          `Risk Level` = "ERROR", Driver = conditionMessage(e),
          check.names = FALSE, stringsAsFactors = FALSE
        )
      })
    })
    df <- do.call(rbind, rows)
    DT::datatable(df, rownames = FALSE, class = "compact stripe",
      options = list(dom = "t", ordering = FALSE, pageLength = 10))
  })

  output$overview_knowledge <- renderUI({
    terms <- tryCatch(read_risk_terms(),       error = function(e) data.frame())
    tagList(
      div(class = "section-label", "Risk Terms"),
      if (nrow(terms) > 0) {
        lapply(seq_len(nrow(terms)), function(i)
          div(class = "knowledge-card",
            div(class = "knowledge-title", terms$term[[i]]),
            p(class = "knowledge-copy", terms$definition[[i]]),
            if (!is.null(terms$implication) && nzchar(terms$implication[[i]]))
              p(class = "knowledge-foot", terms$implication[[i]])
          ))
      } else p("No risk terms found.")
    )
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

  # ── Alert Log & Ops ────────────────────────────────────────────────────

  ops_alerts <- reactivePoll(
    intervalMillis = 2500, session = session,
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
      history$reference_type <- vapply(history$reference_type, title_case, character(1))
    if ("reference_level" %in% names(history))
      history$reference_level <- vapply(history$reference_level, format_dollar, character(1), accuracy = 0.01)
    cols <- intersect(
      c("alert_id", "received_at", "symbol", "event_type",
        "reference_type", "reference_level",
        "risk_level", "primary_driver", "headline"),
      names(history)
    )
    DT::datatable(history[, cols], rownames = FALSE, selection = "single",
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
  output$ops_memo_output <- renderUI({
    d <- ops_detail()
    if (is.null(d)) return(p("Select a row above."))
    tagList(
      div(class = "memo-headline", safe_chr(d$memo$headline, "")),
      tags$pre(class = "memo-body", safe_chr(d$memo$memo, "")),
      if (nzchar(safe_chr(d$memo$recommended_action, "")))
        div(class = "memo-action",
            strong("Next step: "), safe_chr(d$memo$recommended_action, ""))
    )
  })

  output$ops_knowledge_viewer <- renderUI({
    d <- ops_detail()
    selected_symbol <- if (!is.null(d)) {
      safe_chr(d$alert$symbol, default = "")
    } else if (!is.null(input$ops_asset_filter) && input$ops_asset_filter != "All") {
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
        span("Assets: ", paste(APP_ASSETS$label, collapse = ", ")))
    )
  })
}
