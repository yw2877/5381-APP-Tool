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

  out <- as.character(x[[1]])
  if (!nzchar(trimws(out))) {
    return(default)
  }

  out
}

safe_num <- function(x, default = NA_real_) {
  out <- suppressWarnings(as.numeric(x[[1]]))
  if (!is.finite(out)) {
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
  if (is.null(txt) || length(txt) == 0) {
    return(NULL)
  }

  txt <- safe_chr(txt, default = "")
  if (!nzchar(txt)) {
    return(NULL)
  }

  jsonlite::fromJSON(txt, simplifyVector = FALSE)
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
  out <- APP_ASSETS[APP_ASSETS$symbol == safe_chr(symbol, default = "SPY"), , drop = FALSE]
  if (nrow(out) == 0) {
    return(APP_ASSETS[1, , drop = FALSE])
  }
  out
}
