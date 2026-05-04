# ============================================================================
# Plotly dark theme — applied to every chart so axes match the Stealth-Ops
# styles.css palette. Pass the result of plot_ly() through `apply_plotly_dark()`
# at the end of the layout chain.
# ============================================================================
.PLOTLY_DARK_AXIS <- list(
  gridcolor     = "#1c1f24",
  zerolinecolor = "#1c1f24",
  linecolor     = "#252830",
  tickcolor     = "#252830",
  tickfont      = list(color = "#7e8593",
                       family = "ui-monospace, JetBrains Mono, Menlo, monospace",
                       size = 10),
  titlefont     = list(color = "#7e8593",
                       family = "Inter, system-ui, sans-serif",
                       size  = 11),
  showgrid      = TRUE
)

# Merge the dark axis defaults with chart-specific overrides
# (title, range, tickformat, type, etc).
plotly_axis <- function(...) {
  utils::modifyList(.PLOTLY_DARK_AXIS, list(...))
}

apply_plotly_dark <- function(p) {
  plotly::layout(
    p,
    paper_bgcolor = "rgba(0,0,0,0)",
    plot_bgcolor  = "rgba(0,0,0,0)",
    font          = list(color = "#e6e8ec",
                         family = "Inter, system-ui, sans-serif",
                         size = 11),
    legend        = list(bgcolor = "rgba(0,0,0,0)",
                         bordercolor = "#252830",
                         font = list(color = "#e6e8ec", size = 10)),
    hoverlabel    = list(bgcolor = "#1c1f24",
                         bordercolor = "#252830",
                         font = list(color = "#e6e8ec", family = "ui-monospace, JetBrains Mono, Menlo, monospace", size = 11))
  )
}

`%||%` <- function(x, y) {
  if (is.null(x) || length(x) == 0) {
    return(y)
  }

  if (is.character(x)) {
    x1 <- trimws(as.character(x[[1]]))
    if (!nzchar(x1)) {
      return(y)
    }
  }

  x
}

safe_chr <- function(x, default = "") {
  if (is.null(x) || length(x) == 0) {
    return(default)
  }
  first <- x[[1]]
  if (is.null(first) || length(first) == 0) {
    return(default)
  }
  out <- suppressWarnings(as.character(first))
  if (length(out) == 0 || is.na(out)) {
    return(default)
  }
  if (!nzchar(trimws(out))) {
    return(default)
  }
  out
}

safe_num <- function(x, default = NA_real_) {
  if (is.null(x) || length(x) == 0) {
    return(default)
  }
  first <- x[[1]]
  if (is.null(first) || length(first) == 0) {
    return(default)
  }
  out <- suppressWarnings(as.numeric(first))
  if (length(out) == 0 || !is.finite(out)) {
    return(default)
  }
  out
}

safe_time <- function(x, default = Sys.time()) {
  if (inherits(x, c("POSIXct", "POSIXt"))) {
    return(as.POSIXct(x))
  }

  out <- suppressWarnings(as.POSIXct(as.character(x), tz = Sys.timezone()))
  if (is.na(out)) {
    return(default)
  }

  out
}

format_ts <- function(x) {
  out <- safe_time(x)
  format(out, "%Y-%m-%d %H:%M:%S %Z")
}

format_pct <- function(x, accuracy = 0.1) {
  out <- safe_num(x, default = NA_real_)
  if (is.na(out)) {
    return("NA")
  }
  scales::percent(out, accuracy = accuracy)
}

format_dollar <- function(x, accuracy = 1) {
  out <- safe_num(x, default = NA_real_)
  if (is.na(out)) {
    return("NA")
  }
  scales::dollar(out, accuracy = accuracy)
}

format_number <- function(x, accuracy = 0.01) {
  out <- safe_num(x, default = NA_real_)
  if (is.na(out)) {
    return("NA")
  }
  scales::number(out, accuracy = accuracy)
}

title_case <- function(x) {
  tools::toTitleCase(gsub("_", " ", safe_chr(x, default = "")))
}

clip01 <- function(x) {
  max(0, min(1, safe_num(x, default = 0)))
}

symbol_seed <- function(symbol) {
  sum(utf8ToInt(safe_chr(symbol, default = "SPY")))
}

json_pretty <- function(x) {
  jsonlite::prettify(
    jsonlite::toJSON(
      x,
      auto_unbox = TRUE,
      null = "null",
      pretty = FALSE
    )
  )
}

parse_json_safely <- function(txt) {
  # Handles NA / NULL / empty / malformed input. Returns NULL on any failure
  # so downstream fetch_*() callers can treat "no data yet" uniformly with
  # "data exists but couldn't parse". Critical for async webhook ingestion:
  # /tv-alert writes the alerts row first and the analyses row later, so
  # parse_json_safely(NA) is hit on every read in between.
  if (is.null(txt) || length(txt) == 0) {
    return(NULL)
  }
  first <- txt[[1]]
  if (is.null(first) || length(first) == 0) {
    return(NULL)
  }
  if (is.na(first)) {
    return(NULL)
  }
  txt <- suppressWarnings(as.character(first))
  if (length(txt) == 0 || is.na(txt) || !nzchar(trimws(txt))) {
    return(NULL)
  }
  tryCatch(
    jsonlite::fromJSON(txt, simplifyVector = FALSE),
    error = function(e) NULL
  )
}

risk_level_from_score <- function(score) {
  score <- safe_num(score, default = 0)

  if (score >= 0.72) {
    return("high")
  }
  if (score >= 0.42) {
    return("medium")
  }
  "low"
}

risk_badge_class <- function(level) {
  lvl <- tolower(safe_chr(level, default = "monitor"))
  if (lvl %in% c("low", "medium", "high", "monitor")) {
    return(lvl)
  }
  "monitor"
}

asset_row <- function(symbol) {
  s <- safe_chr(symbol, default = "SPY")
  out <- APP_ASSETS[APP_ASSETS$label == s | APP_ASSETS$symbol == s, , drop = FALSE]
  if (nrow(out) == 0) {
    return(APP_ASSETS[1, , drop = FALSE])
  }
  out[1, , drop = FALSE]
}
