read_risk_terms <- function() {
  utils::read.csv(
    file.path(KNOWLEDGE_DIR, "risk_terms.csv"),
    stringsAsFactors = FALSE
  )
}

read_historical_cases <- function() {
  utils::read.csv(
    file.path(KNOWLEDGE_DIR, "historical_cases.csv"),
    stringsAsFactors = FALSE
  )
}

sort_historical_cases <- function(cases) {
  if (!nrow(cases)) return(cases)

  case_dates <- if ("case_date" %in% names(cases)) {
    suppressWarnings(as.Date(cases$case_date))
  } else {
    rep(as.Date(NA), nrow(cases))
  }

  case_dates[is.na(case_dates)] <- as.Date("1900-01-01")
  cases[order(case_dates, decreasing = TRUE), , drop = FALSE]
}

read_playbook <- function() {
  paste(readLines(PLAYBOOK_PATH, warn = FALSE), collapse = "\n")
}

score_text_match <- function(text, query_tokens) {
  text <- tolower(paste(text, collapse = " "))
  sum(vapply(query_tokens, function(token) grepl(token, text, fixed = TRUE), logical(1)))
}

find_historical_cases <- function(signal_type, symbol, risk_level, limit = 3L) {
  asset <- asset_row(symbol)
  tokens <- unique(
    tolower(
      c(
        safe_chr(signal_type, default = "watchlist_signal"),
        safe_chr(symbol, default = "SPY"),
        safe_chr(asset$asset_class[[1]], default = "ETF"),
        safe_chr(risk_level, default = "medium"),
        "support",
        "resistance",
        "volatility",
        "drawdown"
      )
    )
  )

  cases <- sort_historical_cases(read_historical_cases())
  if (!nrow(cases)) return(cases)

  cases$score <- vapply(
    seq_len(nrow(cases)),
    function(i) {
      score_text_match(
        c(
          cases$asset_class[[i]],
          cases$event_type[[i]],
          cases$case_name[[i]],
          cases$summary[[i]],
          cases$watch_items[[i]],
          if ("case_date" %in% names(cases)) cases$case_date[[i]] else "",
          if ("asset_focus" %in% names(cases)) cases$asset_focus[[i]] else "",
          if ("market_regime" %in% names(cases)) cases$market_regime[[i]] else ""
        ),
        query_tokens = tokens
      )
    },
    numeric(1)
  )

  case_dates <- if ("case_date" %in% names(cases)) {
    suppressWarnings(as.Date(cases$case_date))
  } else {
    rep(as.Date(NA), nrow(cases))
  }
  case_dates[is.na(case_dates)] <- as.Date("1900-01-01")
  cases <- cases[order(-cases$score, case_dates, decreasing = TRUE), , drop = FALSE]

  matched <- cases[cases$score > 0, , drop = FALSE]
  if (!nrow(matched)) {
    matched <- head(cases, limit)
  } else {
    matched <- head(matched, limit)
  }

  matched
}

find_asset_historical_cases <- function(symbol, limit = 4L) {
  cases <- sort_historical_cases(read_historical_cases())
  if (!nrow(cases)) {
    attr(cases, "scope") <- "none"
    attr(cases, "scope_value") <- ""
    attr(cases, "exact_count") <- 0L
    return(cases)
  }

  asset <- asset_row(symbol)
  target_symbol <- toupper(trimws(safe_chr(symbol, default = safe_chr(asset$label[[1]], default = ""))))
  target_class <- toupper(trimws(safe_chr(asset$asset_class[[1]], default = "")))
  exact_count <- 0L

  append_unique_cases <- function(base, addition) {
    if (!nrow(addition)) return(base)
    if (!nrow(base)) return(addition)

    key_cols <- intersect(c("case_name", "case_date", "asset_focus"), names(addition))
    if (!length(key_cols)) {
      key_cols <- intersect(c("case_name"), names(addition))
    }

    if (!length(key_cols)) {
      return(rbind(base, addition))
    }

    base_keys <- apply(base[, key_cols, drop = FALSE], 1, paste, collapse = "||")
    add_keys  <- apply(addition[, key_cols, drop = FALSE], 1, paste, collapse = "||")
    keep_idx  <- !(add_keys %in% base_keys)
    if (!any(keep_idx)) return(base)
    rbind(base, addition[keep_idx, , drop = FALSE])
  }

  out <- cases[0, , drop = FALSE]

  if ("asset_focus" %in% names(cases) && nzchar(target_symbol)) {
    symbol_cases <- cases[toupper(trimws(cases$asset_focus)) == target_symbol, , drop = FALSE]
    if (nrow(symbol_cases)) {
      exact_count <- nrow(symbol_cases)
      out <- append_unique_cases(out, symbol_cases)
    }
  }

  if (nrow(out) < limit && "asset_class" %in% names(cases) && nzchar(target_class)) {
    class_cases <- cases[toupper(trimws(cases$asset_class)) == target_class, , drop = FALSE]
    if (nrow(class_cases)) {
      out <- append_unique_cases(out, class_cases)
    }
  }

  if (nrow(out) < limit) {
    out <- append_unique_cases(out, cases)
  }

  out <- head(out, limit)

  if (exact_count > 0) {
    attr(out, "scope") <- "symbol"
    attr(out, "scope_value") <- target_symbol
  } else if (nrow(out) > 0 && "asset_class" %in% names(out) &&
             any(toupper(trimws(out$asset_class)) == target_class, na.rm = TRUE)) {
    attr(out, "scope") <- "asset_class"
    attr(out, "scope_value") <- target_class
  } else {
    attr(out, "scope") <- "library"
    attr(out, "scope_value") <- "Case Library"
  }

  attr(out, "exact_count") <- exact_count
  out
}

retrieve_knowledge <- function(signal_type, symbol, risk_level) {
  asset <- asset_row(symbol)
  tokens <- unique(
    tolower(
      c(
        safe_chr(signal_type, default = "watchlist_signal"),
        safe_chr(symbol, default = "SPY"),
        safe_chr(asset$asset_class[[1]], default = "ETF"),
        safe_chr(risk_level, default = "medium"),
        "var",
        "drawdown",
        "volatility"
      )
    )
  )

  terms <- read_risk_terms()
  terms$score <- vapply(
    seq_len(nrow(terms)),
    function(i) {
      score_text_match(
        c(terms$term[[i]], terms$keywords[[i]], terms$definition[[i]], terms$implication[[i]]),
        query_tokens = tokens
      )
    },
    numeric(1)
  )

  top_terms <- terms[order(-terms$score), , drop = FALSE]
  top_terms <- head(top_terms[top_terms$score > 0, ], 3)
  if (nrow(top_terms) == 0) {
    top_terms <- head(terms, 2)
  }

  top_cases <- find_historical_cases(
    signal_type = signal_type,
    symbol = symbol,
    risk_level = risk_level,
    limit = 2L
  )
  if (nrow(top_cases) == 0) {
    top_cases <- head(sort_historical_cases(read_historical_cases()), 1)
  }

  playbook_lines <- strsplit(read_playbook(), "\n", fixed = TRUE)[[1]]
  playbook_lines <- trimws(playbook_lines)
  playbook_lines <- playbook_lines[nzchar(playbook_lines)]

  playbook_scores <- vapply(
    playbook_lines,
    score_text_match,
    numeric(1),
    query_tokens = tokens
  )

  top_playbook <- head(playbook_lines[order(-playbook_scores)], 3)
  if (!length(top_playbook)) {
    top_playbook <- head(playbook_lines, 3)
  }

  list(
    terms = split(top_terms[c("term", "definition", "implication")], seq_len(nrow(top_terms))),
    cases = split(top_cases[c("case_name", "summary", "watch_items")], seq_len(nrow(top_cases))),
    playbook = as.list(top_playbook)
  )
}
