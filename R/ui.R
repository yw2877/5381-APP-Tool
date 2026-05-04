# ============================================================================
# R/ui.R — V3 UI
#
# 5 nav pages:
#   1. Equities     — asset dashboard (uses module assetDashboardUI)
#   2. Crypto       — asset dashboard (same module, different assets)
#   3. Risk Overview — cross-asset table + risk terms + playbook
#   4. Quality      — V3 Quality Dashboard (telemetry, scores, iterations)
#   5. Alert Log    — ops view (raw payloads, agent traces, system status)
# ============================================================================

# ========== Shared UI helpers ==========

metric_box <- function(label, value, footnote = NULL) {
  div(
    class = "metric-box",
    div(class = "metric-label", label),
    div(class = "metric-value", value),
    if (!is.null(footnote)) div(class = "metric-footnote", footnote)
  )
}

kpi_box <- function(label, output_id, tooltip = NULL) {
  div(
    class = "kpi-box",
    div(class = "kpi-label",
        label,
        if (!is.null(tooltip)) info_tip(tooltip)),
    uiOutput(output_id)
  )
}

# Small inline tooltip pill. Uses Bootstrap data-bs-toggle for native tooltip.
info_tip <- function(text) {
  tags$span(
    class       = "info-tip",
    `data-bs-toggle` = "tooltip",
    `data-bs-placement` = "top",
    title       = text,
    "?"
  )
}

# ========== App shell: sidebar + compact app-header ==========

# Sidebar nav item — driven by data-tab + JS click handler in keybinds.js
sidebar_nav_item <- function(label, value, icon_glyph, kbd, active_value) {
  is_active <- !is.null(active_value) && identical(active_value, value)
  div(
    class = paste0("sidebar-nav-item", if (is_active) " active" else ""),
    `data-tab` = value,
    onclick = sprintf("Shiny.setInputValue('nav_to', '%s', {priority:'event'})", value),
    span(class = "sidebar-nav-item__icon", icon_glyph),
    span(class = "sidebar-nav-item__label", label),
    span(class = "sidebar-nav-item__kbd", kbd)
  )
}

# Full sidebar — brand + WORKSPACE + 5 nav + bottom system status card.
# Receives the active tab so it can highlight the right item; re-rendered
# server-side via output$app_sidebar whenever input$main_nav changes.
app_sidebar <- function(active_value = "equities") {
  div(
    class = "app-sidebar",
    div(
      class = "app-sidebar__brand",
      div(class = "brand-mark", "M"),
      div(
        class = "app-sidebar__brand-text",
        div(class = "brand-name", "Stress Copilot"),
        div(class = "brand-version", "V3.2.1")
      )
    ),
    div(class = "app-sidebar__heading", "WORKSPACE"),
    sidebar_nav_item("Equities",      "equities", "▤", "⌘1", active_value),
    sidebar_nav_item("Crypto",        "crypto",   "◈", "⌘2", active_value),
    sidebar_nav_item("Risk Overview", "risk",     "▦", "⌘3", active_value),
    sidebar_nav_item("Quality",       "quality",  "◐", "⌘4", active_value),
    sidebar_nav_item("Alert Log",     "alerts",   "❉", "⌘5", active_value),
    div(class = "app-sidebar__spacer"),
    uiOutput("sys_status_card", container = function(...) div(class = "app-sidebar__status", ...))
  )
}

# Compact 14px breadcrumb header per asset page.
# Replaces the legacy hero-strip. Asset selector lives in the breadcrumb;
# Lookback / Event live in a Filters popover; Refresh + Simulate as buttons.
app_header <- function(ns, tab_label, asset_choices, default_asset,
                       lookback_choices, default_lookback, event_choices) {
  div(
    class = "app-header",
    div(
      class = "app-header__crumbs",
      span(class = "dim", tab_label),
      span(class = "sep", "/"),
      tags$div(
        class = "app-header__asset",
        selectInput(ns("asset"), NULL,
          choices  = setNames(asset_choices, asset_choices),
          selected = default_asset,
          width    = "auto")
      ),
      span(class = "sep", "/"),
      span(class = "dim app-header__meta", textOutput(ns("asset_meta"), inline = TRUE))
    ),
    div(
      class = "app-header__actions",
      bslib::popover(
        actionButton(ns("filters_btn"), "Filters",
                     class = "btn btn-outline-secondary",
                     icon = icon("sliders-h")),
        title = "Filters",
        selectInput(ns("lookback"), "Lookback",
                    choices  = lookback_choices,
                    selected = default_lookback,
                    width    = "100%"),
        selectInput(ns("scenario"), "Event",
                    choices  = event_choices,
                    selected = "random",
                    width    = "100%"),
        placement = "bottom",
        options   = list(customClass = "filters-popover")
      ),
      actionButton(ns("refresh_btn"), "Refresh",
                   class = "btn btn-outline-secondary"),
      actionButton(ns("simulate_alert"), "Simulate",
                   class = "btn btn-primary btn-simulate"),
      div(class = "app-header__risk", uiOutput(ns("risk_badge")))
    )
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
tv_widget_html <- function(tv_symbol = "BINANCE:BTCUSDT", container_id = NULL) {
  cfg <- jsonlite::toJSON(list(
    autosize            = TRUE,
    symbol              = tv_symbol,
    interval            = "60",
    timezone            = "America/New_York",
    theme               = "dark",
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

    app_header(ns, page_label, asset_choices, default_asset,
               LOOKBACK_CHOICES, DEFAULT_LOOKBACK, simulated_event_choices()),

    uiOutput(ns("error_banner")),

    div(
      class = "kpi-strip",
      kpi_box("Latest Price",   ns("kpi_price"),
              "Most recent close from Yahoo Finance via quantmod."),
      kpi_box("20D Volatility", ns("kpi_vol"),
              "Annualized standard deviation of log returns over the trailing 20 trading days."),
      kpi_box("Max Drawdown",   ns("kpi_dd"),
              "Largest peak-to-trough loss across the lookback window."),
      kpi_box("1D VaR (95%)",   ns("kpi_var"),
              "1-day Value at Risk at 95% confidence — the loss threshold the asset stays within 19 days out of 20."),
      kpi_box("Regime Score",   ns("kpi_regime"),
              "0 to 1 composite of vol, drawdown, and tail risk. Higher = more stressed regime."),
      kpi_box("Last Alert",     ns("kpi_last_alert"),
              "Timestamp of the most recent stored alert for this asset.")
    ),

    div(
      class = "main-grid",

      div(
        class = "chart-stack",
        card(
          class = "msc-card chart-card",
          card_header("TradingView Chart",
                      info_tip("Live candlestick chart from TradingView. Asset symbol auto-syncs with the dropdown.")),
          div(class = "chart-wrap", uiOutput(ns("tv_chart")))
        ),
        card(
          class = "msc-card",
          card_header("Price & Rolling Volatility",
                      info_tip("Top: closing price. Bottom: trailing 20-day annualized volatility. Both use the same lookback window.")),
          plotly::plotlyOutput(ns("price_vol_chart"), height = "330px", width = "100%")
        )
      ),

      div(
        class = "side-stack",
        # Agent Pipeline · Trace — visualises the agentic loop end-to-end
        # using rows from `agent_runs`. Demo-critical: shows the iter-1 fail →
        # iter-2 pass flow when the Critic forces a rewrite.
        card(
          class = "msc-card agent-trace-card",
          card_header("Agent Pipeline · Trace",
                      uiOutput(ns("agent_trace_meta"), inline = TRUE,
                               class = "header-link")),
          div(class = "agent-trace-card__body",
              uiOutput(ns("agent_trace_html")))
        ),
        # Quality Snapshot — replaces V2's Risk Metrics Snapshot bar chart.
        # Surfaces the Critic Agent's verdict on this alert's memo.
        card(
          class = "msc-card quality-snapshot-card",
          card_header("Critic Dimensions",
                      info_tip("Critic Agent's per-dimension scores for this memo. Pass threshold = 0.75. Bars show actual score; color flags weak dimensions.")),
          uiOutput(ns("quality_snapshot"))
        ),
        card(
          class = "msc-card agent-tabset-card",
          navset_tab(
            id = ns("agent_tab"),
            nav_panel(
              title = tagList(icon("triangle-exclamation"), " Triage"),
              div(class = "agent-tab-body",
                  div(class = "agent-explainer",
                      strong("Triage Agent"),
                      " classifies the alert into a regime category and proposes what to monitor next. ",
                      tags$a(href = "#", onclick = "Shiny.setInputValue('show_prompt', 'triage', {priority: 'event'}); return false;",
                             "View prompt")),
                  uiOutput(ns("triage_panel")))
            ),
            nav_panel(
              title = tagList(icon("chart-bar"), " Risk Engine"),
              div(class = "agent-tab-body",
                  div(class = "agent-explainer",
                      strong("Risk Engine Agent"),
                      " computes deterministic risk metrics (vol, VaR, drawdown, regime score) from real Yahoo Finance prices. No LLM call.",
                      tags$br(),
                      tags$small("This is the Tool Calling component — the agent invokes ", tags$code("compute_risk_metrics()"), ".")),
                  uiOutput(ns("risk_metrics_panel")))
            ),
            nav_panel(
              title = tagList(icon("file-lines"), " Memo"),
              div(class = "agent-tab-body",
                  div(class = "agent-explainer",
                      strong("Memo Agent"),
                      " writes a 3-5 sentence executive memo using triage + metrics + RAG-retrieved context. Re-runs if the Critic rejects it. ",
                      tags$a(href = "#", onclick = "Shiny.setInputValue('show_prompt', 'memo', {priority: 'event'}); return false;",
                             "View prompt")),
                  uiOutput(ns("memo_panel")))
            ),
            nav_panel(
              title = tagList(icon("user-shield"), " Critic"),
              div(class = "agent-tab-body",
                  div(class = "agent-explainer",
                      strong("Critic Agent"),
                      " is the V3 quality gate. Scores the memo on 5 dimensions; if it fails, sends improvement directives back to the Memo Agent. ",
                      tags$a(href = "#", onclick = "Shiny.setInputValue('show_prompt', 'critic', {priority: 'event'}); return false;",
                             "View prompt")),
                  uiOutput(ns("critic_panel")))
            )
          )
        )
      )
    ),

    div(
      style = "margin-top:1rem;",
      card(
        class = "msc-card",
        card_header("Recent Alerts (last 5)",
                    tags$a(class = "header-link", href = "#",
                           onclick = "Shiny.setInputValue('go_to_ops', Math.random(), {priority: 'event'}); return false;",
                           "View full log →")),
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
      div(class = "eyebrow", "RISK OVERVIEW"),
      h2("Cross-asset snapshot"),
      p("All assets · 120D lookback · cached 5 min · refreshes automatically.")
    ),

    # Asset cards — one per APP_ASSETS row. Top border colored by regime score.
    uiOutput("overview_asset_cards"),

    card(
      class = "msc-card",
      style = "margin-top:1rem;",
      card_header("Cross-Asset Risk Table",
                  info_tip("All assets at 120-day lookback. Cells are computed in parallel; cached for 5 min.")),
      div(style = "padding:0.6rem;",
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
        card_header("Playbook",
                    info_tip("Heuristic checklist used by the Memo Agent (and shown to humans for cross-checking).")),
        div(style = "padding:0.8rem; max-height:520px; overflow-y:auto;",
          uiOutput("overview_playbook"))
      )
    )
  )
}

# ========== Page: Quality Dashboard (NEW V3) ==========
page_quality_dashboard <- function() {
  div(
    class = "msc-shell",

    div(
      class = "ops-header",
      h2("Quality Dashboard"),
      p("Evidence of AI performance: pass rate, quality scores over time, dimension breakdown, and iteration distribution from the Critic Agent.")
    ),

    div(
      class = "ops-filters",
      div(
        class = "ops-filter-item",
        selectInput("qd_window", "Time Window",
                    choices  = c("Last hour"  = "1h",
                                 "Last 24h"   = "24h",
                                 "Last 7d"    = "7d",
                                 "All time"   = "all"),
                    selected = "all", width = "100%")
      ),
      div(class = "ops-filter-item",
          actionButton("qd_refresh", "Refresh",
                       icon = icon("rotate"),
                       class = "btn btn-outline-secondary"))
    ),

    # KPI strip — quality-specific
    div(
      class = "kpi-strip",
      kpi_box("Total Alerts",      "qd_kpi_total",
              "Count of alerts processed in the selected window."),
      kpi_box("Avg Quality",       "qd_kpi_avg_score",
              "Mean Critic Agent score across all memos in the window."),
      kpi_box("Pass Rate",         "qd_kpi_pass_rate",
              "Percentage of memos that passed the Critic's threshold (>= 0.75)."),
      kpi_box("Avg Iterations",    "qd_kpi_avg_iter",
              "Average number of memo regenerations per alert. >1 means the loop fired.")
    ),

    card(
      class = "msc-card",
      card_header("Quality Score Over Time",
                  info_tip("Each dot is one alert. Green = passed Critic. Red = failed.")),
      plotlyOutput("qd_time_series", height = "280px")
    ),

    div(
      class = "qd-grid",
      style = "margin-top:1rem;",
      card(
        class = "msc-card",
        card_header("Dimension Breakdown",
                    info_tip("Mean score per Critic dimension. Lowest bar = where the system is weakest.")),
        plotlyOutput("qd_dimensions", height = "280px")
      ),
      card(
        class = "msc-card",
        card_header("Iteration Distribution",
                    info_tip("How many alerts needed 1 vs 2 memo iterations. >1 means the Critic loop forced a rewrite.")),
        plotlyOutput("qd_iterations", height = "280px")
      )
    ),

    card(
      class = "msc-card",
      style = "margin-top:1rem;",
      card_header("Recent Low-Scoring Memos",
                  info_tip("Memos that the Critic gave the lowest scores. Click a row to inspect it on the Alert Log page.")),
      DTOutput("qd_low_scores")
    )
  )
}

# ========== Page: Alert Log & Operations ==========
page_operations <- function() {
  div(
    class = "msc-shell",

    div(
      class = "ops-header",
      div(class = "eyebrow", "ALERT LOG & OPS"),
      h2("Pipeline runs · last 24h"),
      p("Click a row in the master list; the detail pane on the right inspects the raw payload, risk metrics, memo + critic verdict, and live system status.")
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

    # Master / detail split.
    # Left = full alert table (master). Right = stack of payload cards
    # (raw / risk / memo+critic / system) — driven by the row clicked on the left.
    div(
      class = "ops-split",
      div(
        class = "ops-split__master",
        card(
          class = "msc-card",
          card_header("Full Alert History"),
          DTOutput("ops_alert_table")
        )
      ),
      div(
        class = "ops-split__detail",
        div(class = "payload",
          div(class = "payload__label blue", "RAW PAYLOAD"),
          tags$pre(textOutput("ops_raw_payload"))
        ),
        div(class = "payload",
          div(class = "payload__label blue", "TRIAGE OUTPUT"),
          tags$pre(textOutput("ops_triage_json"))
        ),
        div(class = "payload",
          div(class = "payload__label purple", "RISK METRICS · TOOL OUTPUT"),
          tags$pre(textOutput("ops_metrics_json"))
        ),
        div(class = "payload",
          div(class = "payload__label amber", "MEMO + CRITIQUE"),
          uiOutput("ops_memo_output")
        ),
        div(class = "payload",
          div(class = "payload__label acid", "SYSTEM STATUS"),
          uiOutput("ops_system_status")
        )
      )
    ),

    # Below the split — historical cases + per-alert agent telemetry.
    div(
      class = "ops-bottom-grid",
      style = "margin-top:1rem;",
      card(
        class = "msc-card",
        card_header("Historical Cases"),
        uiOutput("ops_knowledge_viewer")
      ),
      card(
        class = "msc-card",
        card_header("Agent Run Telemetry (selected alert)",
                    info_tip("Per-agent latency, retries, and validation status for the alert selected above.")),
        DTOutput("ops_agent_runs")
      )
    )
  )
}

# ========== Welcome modal (first-load) ==========
welcome_modal <- function() {
  modalDialog(
    title = "Welcome to Market Stress Copilot",
    size  = "l",
    easyClose = TRUE,
    footer = tagList(
      checkboxInput("welcome_dont_show", "Don't show this again", value = FALSE),
      modalButton("Got it")
    ),
    div(
      class = "welcome-body",
      tags$h4("What this app does"),
      p("Translates a raw market alert (e.g. a TradingView signal) into a 30-second risk briefing using a four-agent pipeline."),

      tags$h4("The four agents"),
      tags$ul(
        tags$li(strong("Triage"), " — classifies the signal type and severity."),
        tags$li(strong("Risk Engine"), " — computes deterministic risk metrics (VaR, vol, drawdown) from real Yahoo Finance data."),
        tags$li(strong("Memo"), " — writes a concise executive memo, RAG-augmented with our risk-term + historical-case knowledge base."),
        tags$li(strong("Critic"), " — V3's quality gate. Scores the memo and loops back if it fails.")
      ),

      tags$h4("Three personas"),
      tags$ul(
        tags$li(strong("Trader"), " — sees just the memo + recommended action."),
        tags$li(strong("Risk Officer"), " — sees memo + critic critique + matched historical cases."),
        tags$li(strong("Quant"), " — sees the full agent telemetry and Quality Dashboard.")
      ),

      tags$h4("Try it now"),
      p("Click ", strong("Simulate"), " on the Equities or Crypto tab to fire a fake TradingView alert through the pipeline. Then check the Quality Dashboard to see the score.")
    )
  )
}

# ========== Agent prompt modal ==========
agent_prompt_modal <- function(agent_key) {
  prompts <- list(
    triage = list(
      title = "Triage Agent — System Prompt",
      body  = .triage_system_prompt()
    ),
    memo = list(
      title = "Memo Agent — System Prompt",
      body  = .memo_system_prompt()
    ),
    critic = list(
      title = "Critic Agent — System Prompt",
      body  = .critic_system_prompt()
    )
  )
  spec <- prompts[[agent_key]]
  if (is.null(spec)) return(NULL)

  modalDialog(
    title = spec$title,
    size  = "l",
    easyClose = TRUE,
    footer = modalButton("Close"),
    tags$pre(class = "json-trace", style = "max-height:60vh;",
             spec$body)
  )
}

# ========== Main app UI ==========
app_ui <- function() {
  bslib::page_fluid(
    title = APP_TITLE,
    theme = bs_theme(
      version      = 5,
      bg           = "#0d0e10",
      fg           = "#e6e8ec",
      primary      = "#a3ff12",
      secondary    = "#7e8593",
      base_font    = font_google("Inter"),
      heading_font = font_google("Inter"),
      font_scale   = 0.92
    ),
    tags$head(
      includeCSS("www/styles.css"),
      includeScript("www/keybinds.js"),
      includeScript("www/tweaks.js"),
      tags$script(HTML("
        // Initialize Bootstrap tooltips after every render
        $(document).on('shiny:idle', function() {
          var tts = document.querySelectorAll('[data-bs-toggle=\"tooltip\"]');
          tts.forEach(function(el) {
            if (!el._tt_init) {
              new bootstrap.Tooltip(el);
              el._tt_init = true;
            }
          });
        });
        // Welcome modal: show once per browser, then persist
        $(document).on('shiny:connected', function() {
          if (!localStorage.getItem('msc_welcome_seen')) {
            Shiny.setInputValue('show_welcome', Math.random(),
                                {priority: 'event'});
          }
        });
        // Server can mark the welcome modal seen
        Shiny.addCustomMessageHandler('set_welcome_seen', function(_) {
          localStorage.setItem('msc_welcome_seen', '1');
        });
      "))
    ),
    div(
      class = "app-shell",
      uiOutput("app_sidebar_ui"),
      div(
        class = "app-main",
        tabsetPanel(
          id   = "main_nav",
          type = "hidden",
          tabPanelBody("equities", page_equities()),
          tabPanelBody("crypto",   page_crypto()),
          tabPanelBody("risk",     page_risk_overview()),
          tabPanelBody("quality",  page_quality_dashboard()),
          tabPanelBody("alerts",   page_operations())
        )
      )
    )
  )
}
