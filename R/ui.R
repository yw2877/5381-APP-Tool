metric_box <- function(label, value, footnote = NULL) {
  div(
    class = "metric-box",
    div(class = "metric-label", label),
    div(class = "metric-value", value),
    if (!is.null(footnote)) div(class = "metric-footnote", footnote)
  )
}

kpi_box <- function(label, output_id) {
  div(
    class = "kpi-box",
    div(class = "kpi-label", label),
    uiOutput(output_id)
  )
}

# ---------- TradingView widget HTML ----------
tv_widget_html <- function(tv_symbol = "BINANCE:BTCUSDT") {
  tags$div(
    class = "tv-chart-container",
    tags$div(
      id = "tv_chart_widget",
      style = "width:100%;height:420px;"
    ),
    tags$script(type = "text/javascript", src = "https://s3.tradingview.com/tv.js"),
    tags$script(HTML(sprintf('
      new TradingView.widget({
        "container_id": "tv_chart_widget",
        "autosize": true,
        "symbol": "%s",
        "interval": "60",
        "timezone": "America/New_York",
        "theme": "light",
        "style": "1",
        "locale": "en",
        "toolbar_bg": "#f1f3f6",
        "enable_publishing": false,
        "hide_side_toolbar": false,
        "allow_symbol_change": true,
        "studies": ["BB@tv-basicstudies", "ATR@tv-basicstudies"],
        "save_image": false
      });
    ', tv_symbol)))
  )
}

# ========== Page 1: Executive Risk Dashboard ==========
page_dashboard <- function() {
  div(
    class = "msc-shell",

    # Hero strip
    div(
      class = "hero-strip",
      div(
        class = "hero-copy",
        div(class = "eyebrow", "Agentic Risk App v2"),
        h1(APP_TITLE),
        p(APP_SUBTITLE)
      ),
      div(
        class = "control-strip",
        div(
          class = "control-block",
          span(class = "control-label", "Asset"),
          selectInput("asset", NULL, choices = setNames(APP_ASSETS$label, APP_ASSETS$label), selected = APP_ASSETS$label[[1]], width = "100%")
        ),
        div(
          class = "control-block",
          span(class = "control-label", "Lookback"),
          selectInput("lookback", NULL, choices = LOOKBACK_CHOICES, selected = DEFAULT_LOOKBACK, width = "100%")
        ),
        div(
          class = "control-block action-block",
          span(class = "control-label", "Alert"),
          actionButton("simulate_alert", "Simulate Alert", class = "btn btn-primary w-100")
        ),
        div(
          class = "control-block action-block",
          span(class = "control-label", "Refresh"),
          actionButton("refresh_btn", "Refresh", class = "btn btn-outline-light w-100")
        ),
        div(
          class = "status-block",
          span(class = "control-label", "Current Risk"),
          uiOutput("risk_badge")
        )
      )
    ),

    # KPI strip
    div(
      class = "kpi-strip",
      kpi_box("Latest Price", "kpi_price"),
      kpi_box("20D Volatility", "kpi_vol"),
      kpi_box("Max Drawdown", "kpi_dd"),
      kpi_box("1D VaR (95%)", "kpi_var"),
      kpi_box("Regime Score", "kpi_regime"),
      kpi_box("Last Alert", "kpi_last_alert")
    ),

    # Main grid: chart + agent panels
    div(
      class = "main-grid",
      card(
        class = "msc-card chart-card",
        card_header("TradingView Chart"),
        div(class = "chart-wrap", uiOutput("tv_chart"))
      ),
      div(
        class = "side-stack",
        card(
          class = "msc-card",
          card_header("Signal Triage Agent"),
          uiOutput("triage_panel")
        ),
        card(
          class = "msc-card",
          card_header("Risk Engine Agent"),
          uiOutput("risk_metrics_panel")
        ),
        card(
          class = "msc-card memo-card",
          card_header("Risk Memo Agent"),
          uiOutput("memo_panel")
        )
      )
    ),

    # Bottom grid: alert feed + knowledge
    div(
      class = "bottom-grid",
      card(
        class = "msc-card",
        card_header("Alert Feed"),
        DTOutput("alert_history")
      ),
      card(
        class = "msc-card",
        card_header("Knowledge + Similar Cases"),
        uiOutput("knowledge_panel")
      )
    )
  )
}

# ========== Page 2: Alert Log & Operations ==========
page_operations <- function() {
  div(
    class = "msc-shell",

    div(
      class = "ops-header",
      h2("Alert Log & Operations"),
      p("Technical review, raw payloads, agent traces, and system status.")
    ),

    # Filters
    div(
      class = "ops-filters",
      div(
        class = "ops-filter-item",
        selectInput("ops_asset_filter", "Filter by Asset",
                    choices = c("All", APP_ASSETS$label),
                    selected = "All", width = "100%")
      ),
      div(
        class = "ops-filter-item",
        selectInput("ops_type_filter", "Filter by Event Type",
                    choices = c("All", "bollinger_breakdown", "atr_expansion",
                                "death_cross_volume", "break_prior_low",
                                "baseline_check", "watchlist_signal"),
                    selected = "All", width = "100%")
      )
    ),

    # Full alert history table
    card(
      class = "msc-card",
      card_header("Full Alert History"),
      DTOutput("ops_alert_table")
    ),

    # Detail panels
    div(
      class = "ops-detail-grid",

      card(
        class = "msc-card",
        card_header("Raw Webhook Payload"),
        tags$pre(class = "json-trace", textOutput("ops_raw_payload"))
      ),

      card(
        class = "msc-card",
        card_header("Triage Agent JSON"),
        tags$pre(class = "json-trace", textOutput("ops_triage_json"))
      ),

      card(
        class = "msc-card",
        card_header("Risk Metrics JSON"),
        tags$pre(class = "json-trace", textOutput("ops_metrics_json"))
      ),

      card(
        class = "msc-card",
        card_header("Memo Output"),
        uiOutput("ops_memo_output")
      )
    ),

    # Knowledge base + system status
    div(
      class = "ops-bottom-grid",
      card(
        class = "msc-card",
        card_header("Knowledge Base Viewer"),
        uiOutput("ops_knowledge_viewer")
      ),
      card(
        class = "msc-card",
        card_header("System Status"),
        uiOutput("ops_system_status")
      )
    )
  )
}

# ========== Main app UI ==========
app_ui <- function() {
  page_navbar(
    id = "main_nav",
    title = NULL,
    theme = bs_theme(
      version = 5,
      bg = "#F5EFE6",
      fg = "#16202B",
      primary = "#A55B28",
      secondary = "#0D6E7E",
      base_font = font_google("Manrope"),
      heading_font = font_google("IBM Plex Sans")
    ),
    header = tags$head(includeCSS("www/styles.css")),
    nav_panel(
      title = "Dashboard",
      icon = icon("chart-line"),
      page_dashboard()
    ),
    nav_panel(
      title = "Alert Log & Ops",
      icon = icon("clipboard-list"),
      page_operations()
    )
  )
}
