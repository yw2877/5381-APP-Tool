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

read_playbook <- function() {
  paste(readLines(PLAYBOOK_PATH, warn = FALSE), collapse = "\n")
}

score_text_match <- function(text, query_tokens) {
  text <- tolower(paste(text, collapse = " "))
  sum(vapply(query_tokens, function(token) grepl(token, text, fixed = TRUE), logical(1)))
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

  cases <- read_historical_cases()
  cases$score <- vapply(
    seq_len(nrow(cases)),
    function(i) {
      score_text_match(
        c(cases$asset_class[[i]], cases$event_type[[i]], cases$case_name[[i]], cases$summary[[i]], cases$watch_items[[i]]),
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

  top_cases <- cases[order(-cases$score), , drop = FALSE]
  top_cases <- head(top_cases[top_cases$score > 0, ], 2)
  if (nrow(top_cases) == 0) {
    top_cases <- head(cases, 1)
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
