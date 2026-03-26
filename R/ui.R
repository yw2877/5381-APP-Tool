metric_box <- function(label, value, footnote = NULL) {
  div(
    class = "metric-box",
    div(class = "metric-label", label),
    div(class = "metric-value", value),
    if (!is.null(footnote)) div(class = "metric-footnote", footnote)
  )
}

app_ui <- function() {
  page_fillable(
    theme = bs_theme(
      version = 5,
      bg = "#F5EFE6",
      fg = "#16202B",
      primary = "#A55B28",
      secondary = "#0D6E7E",
      base_font = font_google("Manrope"),
      heading_font = font_google("IBM Plex Sans")
    ),
    tags$head(
      includeCSS("www/styles.css")
    ),
    div(
      class = "msc-shell",
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
            selectInput("asset", NULL, choices = APP_ASSETS$symbol, selected = APP_ASSETS$symbol[[1]], width = "100%")
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
            class = "status-block",
            span(class = "control-label", "Current Risk"),
            uiOutput("risk_badge")
          )
        )
      ),
      div(
        class = "main-grid",
        card(
          class = "msc-card chart-card",
          card_header("Chart Slot"),
          div(
            class = "chart-wrap",
            plotOutput("fallback_price_plot", height = 320),
            uiOutput("tv_slot")
          )
        ),
        div(
          class = "side-stack",
          card(
            class = "msc-card",
            card_header("Signal Triage Agent"),
            uiOutput("triage_panel"),
            tags$pre(class = "json-trace", textOutput("triage_json"))
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
  )
}
