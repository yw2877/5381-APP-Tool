# ========== Shared UI helpers ==========

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

simulated_event_choices <- function() {
  event_types <- unique(vapply(
    SIMULATED_EVENT_LIBRARY,
    function(item) safe_chr(item$event_type, default = "watchlist_signal"),
    character(1)
  ))
  event_labels <- vapply(event_types, title_case, character(1))

  c(
    "Random" = "random",
    stats::setNames(event_types, event_labels)
  )
}

# ---------- TradingView widget HTML ----------
# Uses TradingView's official iframe embed; no JS initialisation or race
# conditions. The iframe is self-contained.
tv_widget_html <- function(tv_symbol = "BINANCE:BTCUSDT", container_id = NULL) {
  cfg <- jsonlite::toJSON(list(
    autosize            = TRUE,
    symbol              = tv_symbol,
    interval            = "60",
    timezone            = "America/New_York",
    theme               = "light",
    style               = "1",
    locale              = "en",
    allow_symbol_change = TRUE,
    support_host        = "https://www.tradingview.com"
  ), auto_unbox = TRUE, pretty = FALSE)

  iframe_src <- paste0(
    "https://s.tradingview.com/embed-widget/advanced-chart/?locale=en#",
    cfg
  )

  tags$div(
    class = "tv-chart-container",
    tags$iframe(
      src               = iframe_src,
      width             = "100%",
      height            = "390px",
      frameborder       = "0",
      allowtransparency = "true",
      scrolling         = "no",
      style             = "border:none; display:block;"
    )
  )
}

# ========== Asset Dashboard Module UI ==========

assetDashboardUI <- function(id, asset_choices, default_asset, page_label) {
  ns <- NS(id)
  div(
    class = "msc-shell",

    div(
      class = "hero-strip",
      div(
        class = "hero-copy",
        div(class = "eyebrow", page_label),
        h1(APP_TITLE),
        p(APP_SUBTITLE)
      ),
      div(
        class = "control-strip",
        div(
          class = "control-block",
          span(class = "control-label", "Asset"),
          selectInput(ns("asset"), NULL,
            choices  = setNames(asset_choices, asset_choices),
            selected = default_asset,
            width    = "100%")
        ),
        div(
          class = "control-block",
          span(class = "control-label", "Lookback"),
          selectInput(ns("lookback"), NULL,
            choices  = LOOKBACK_CHOICES,
            selected = DEFAULT_LOOKBACK,
            width    = "100%")
        ),
        div(
          class = "control-block",
          span(class = "control-label", "Event"),
          selectInput(ns("scenario"), NULL,
            choices  = simulated_event_choices(),
            selected = "random",
            width    = "100%")
        ),
        div(
          class = "control-block action-block",
          span(class = "control-label", "Alert"),
          actionButton(ns("simulate_alert"), "Simulate",
                       class = "btn btn-primary w-100")
        ),
        div(
          class = "control-block action-block",
          span(class = "control-label", "Refresh"),
          actionButton(ns("refresh_btn"), "Refresh",
                       class = "btn btn-outline-light w-100")
        ),
        div(
          class = "status-block",
          span(class = "control-label", "Current Risk"),
          uiOutput(ns("risk_badge"))
        )
      )
    ),

    uiOutput(ns("error_banner")),

    div(
      class = "kpi-strip",
      kpi_box("Latest Price",   ns("kpi_price")),
      kpi_box("20D Volatility", ns("kpi_vol")),
      kpi_box("Max Drawdown",   ns("kpi_dd")),
      kpi_box("1D VaR (95%)",   ns("kpi_var")),
      kpi_box("Regime Score",   ns("kpi_regime")),
      kpi_box("Last Alert",     ns("kpi_last_alert"))
    ),

    div(
      class = "main-grid",

      div(
        class = "chart-stack",
        card(
          class = "msc-card chart-card",
          card_header("TradingView Chart"),
          div(class = "chart-wrap", uiOutput(ns("tv_chart")))
        ),
        card(
          class = "msc-card",
          card_header("Price & Rolling Volatility"),
          plotly::plotlyOutput(ns("price_vol_chart"), height = "330px", width = "100%")
        )
      ),

      div(
        class = "side-stack",
        card(
          class = "msc-card",
          card_header("Risk Metrics Snapshot"),
          plotly::plotlyOutput(ns("risk_bar_chart"), height = "205px")
        ),
        card(
          class = "msc-card agent-tabset-card",
          navset_tab(
            id = ns("agent_tab"),
            nav_panel(
              title = tagList(icon("triangle-exclamation"), " Triage"),
              div(class = "agent-tab-body", uiOutput(ns("triage_panel")))
            ),
            nav_panel(
              title = tagList(icon("chart-bar"), " Risk Engine"),
              div(class = "agent-tab-body", uiOutput(ns("risk_metrics_panel")))
            ),
            nav_panel(
              title = tagList(icon("file-lines"), " Memo"),
              div(class = "agent-tab-body", uiOutput(ns("memo_panel")))
            )
          )
        )
      )
    ),

    div(
      style = "margin-top:1rem;",
      card(
        class = "msc-card",
        card_header("Recent Alerts"),
        DTOutput(ns("alert_history"))
      )
    )
  )
}

# ========== Page: Crypto ==========
page_crypto <- function() {
  crypto_assets <- APP_ASSETS$label[APP_ASSETS$asset_class == "Crypto"]
  assetDashboardUI("crypto", crypto_assets, crypto_assets[[1]],
                   "Crypto Dashboard")
}

# ========== Page: Equities ==========
page_equities <- function() {
  eq_assets <- APP_ASSETS$label[APP_ASSETS$asset_class %in% c("ETF", "Equity")]
  assetDashboardUI("equity", eq_assets, eq_assets[[1]],
                   "Equities Dashboard")
}

# ========== Page: Risk Overview ==========
page_risk_overview <- function() {
  div(
    class = "msc-shell",

    div(
      class = "ops-header",
      h2("Risk Overview"),
      p("Cross-asset risk metrics snapshot, risk terms, and playbook.")
    ),

    card(
      class = "msc-card",
      card_header("Cross-Asset Risk Table"),
      div(style = "padding:0.6rem;",
        p(class = "inline-meta",
          "Metrics computed at 120-day lookback. Refresh the page to update."),
        DTOutput("overview_risk_table")
      )
    ),

    div(
      class = "bottom-grid",
      style = "margin-top:1rem;",
      card(
        class = "msc-card",
        card_header("Risk Terms"),
        div(style = "padding:0.8rem;",
          uiOutput("overview_knowledge"))
      ),
      card(
        class = "msc-card",
        card_header("Playbook"),
        div(style = "padding:0.8rem; max-height:520px; overflow-y:auto;",
          uiOutput("overview_playbook"))
      )
    )
  )
}

# ========== Page: Alert Log & Operations ==========
page_operations <- function() {
  div(
    class = "msc-shell",

    div(
      class = "ops-header",
      h2("Alert Log & Operations"),
      p("Technical review, raw payloads, agent traces, matched historical cases, and system status.")
    ),

    div(
      class = "ops-filters",
      div(
        class = "ops-filter-item",
        selectInput("ops_asset_filter", "Filter by Asset",
                    choices  = c("All", APP_ASSETS$label),
                    selected = "All", width = "100%")
      ),
      div(
        class = "ops-filter-item",
        selectInput("ops_type_filter", "Filter by Event Type",
                    choices  = c("All", "bollinger_breakdown", "atr_expansion",
                                 "death_cross_volume", "break_prior_low",
                                 "support_break", "resistance_break",
                                 "baseline_check", "watchlist_signal"),
                    selected = "All", width = "100%")
      )
    ),

    card(
      class = "msc-card",
      card_header("Full Alert History"),
      DTOutput("ops_alert_table")
    ),

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

    div(
      class = "ops-bottom-grid",
      card(
        class = "msc-card",
        card_header("Historical Cases"),
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
    id    = "main_nav",
    title = APP_TITLE,
    theme = bs_theme(
      version      = 5,
      bg           = "#f5f5f5",
      fg           = "#1a1a1a",
      primary      = "#B31B1B",
      secondary    = "#2d2d2d",
      base_font    = font_google("Inter"),
      heading_font = font_google("Inter")
    ),
    header = tags$head(
      includeCSS("www/styles.css")
    ),
    nav_panel(
      title = "Equities",
      icon  = icon("chart-bar"),
      page_equities()
    ),
    nav_panel(
      title = "Crypto",
      icon  = icon("coins"),
      page_crypto()
    ),
    nav_panel(
      title = "Risk Overview",
      icon  = icon("table"),
      page_risk_overview()
    ),
    nav_panel(
      title = "Alert Log & Ops",
      icon  = icon("clipboard-list"),
      page_operations()
    )
  )
}
