db_connect <- function() {
  DBI::dbConnect(RSQLite::SQLite(), APP_DB_PATH)
}

ensure_runtime_state <- function() {
  dir.create(dirname(APP_DB_PATH), recursive = TRUE, showWarnings = FALSE)
  dir.create(KNOWLEDGE_DIR, recursive = TRUE, showWarnings = FALSE)
  initialize_storage()
  invisible(TRUE)
}

initialize_storage <- function() {
  conn <- db_connect()
  on.exit(DBI::dbDisconnect(conn), add = TRUE)

  DBI::dbExecute(
    conn,
    paste(
      "CREATE TABLE IF NOT EXISTS alerts (",
      "id INTEGER PRIMARY KEY AUTOINCREMENT,",
      "received_at TEXT NOT NULL,",
      "symbol TEXT NOT NULL,",
      "event_type TEXT NOT NULL,",
      "source TEXT NOT NULL,",
      "trigger_price REAL,",
      "message TEXT,",
      "raw_payload_json TEXT NOT NULL",
      ");"
    )
  )

  DBI::dbExecute(
    conn,
    paste(
      "CREATE TABLE IF NOT EXISTS analyses (",
      "alert_id INTEGER PRIMARY KEY,",
      "created_at TEXT NOT NULL,",
      "risk_level TEXT,",
      "primary_driver TEXT,",
      "headline TEXT,",
      "memo_text TEXT,",
      "triage_json TEXT,",
      "metrics_json TEXT,",
      "knowledge_json TEXT,",
      "FOREIGN KEY(alert_id) REFERENCES alerts(id)",
      ");"
    )
  )

  invisible(TRUE)
}

insert_alert_record <- function(alert, raw_payload) {
  conn <- db_connect()
  on.exit(DBI::dbDisconnect(conn), add = TRUE)

  row <- tibble::tibble(
    received_at = format_ts(alert$received_at),
    symbol = safe_chr(alert$symbol, default = "SPY"),
    event_type = safe_chr(alert$event_type, default = "watchlist_signal"),
    source = safe_chr(alert$source, default = "unknown"),
    trigger_price = safe_num(alert$trigger_price, default = NA_real_),
    message = safe_chr(alert$message, default = ""),
    raw_payload_json = jsonlite::toJSON(
      raw_payload,
      auto_unbox = TRUE,
      null = "null"
    )
  )

  DBI::dbWriteTable(conn, "alerts", row, append = TRUE)
  DBI::dbGetQuery(conn, "SELECT last_insert_rowid() AS id;")$id[[1]]
}

save_analysis_record <- function(alert_id, analysis) {
  conn <- db_connect()
  on.exit(DBI::dbDisconnect(conn), add = TRUE)

  DBI::dbExecute(
    conn,
    sprintf("DELETE FROM analyses WHERE alert_id = %d;", as.integer(alert_id))
  )

  row <- tibble::tibble(
    alert_id = as.integer(alert_id),
    created_at = format_ts(Sys.time()),
    risk_level = safe_chr(analysis$risk$risk_level, default = "monitor"),
    primary_driver = safe_chr(analysis$risk$primary_driver, default = "baseline"),
    headline = safe_chr(analysis$memo$headline, default = ""),
    memo_text = safe_chr(analysis$memo$memo, default = ""),
    triage_json = jsonlite::toJSON(
      analysis$triage,
      auto_unbox = TRUE,
      null = "null"
    ),
    metrics_json = jsonlite::toJSON(
      analysis$risk,
      auto_unbox = TRUE,
      null = "null"
    ),
    knowledge_json = jsonlite::toJSON(
      analysis$knowledge,
      auto_unbox = TRUE,
      null = "null"
    )
  )

  DBI::dbWriteTable(conn, "analyses", row, append = TRUE)
  invisible(alert_id)
}

fetch_alert_history <- function(limit = 25L) {
  conn <- db_connect()
  on.exit(DBI::dbDisconnect(conn), add = TRUE)

  sql <- glue::glue(
    "
    SELECT
      a.id AS alert_id,
      a.received_at,
      a.symbol,
      a.event_type,
      a.source,
      a.trigger_price,
      a.message,
      n.risk_level,
      n.primary_driver,
      n.headline
    FROM alerts a
    LEFT JOIN analyses n ON a.id = n.alert_id
    ORDER BY a.id DESC
    LIMIT {as.integer(limit)};
    "
  )

  DBI::dbGetQuery(conn, sql)
}

fetch_analysis_by_id <- function(alert_id) {
  conn <- db_connect()
  on.exit(DBI::dbDisconnect(conn), add = TRUE)

  sql <- sprintf(
    "SELECT a.id AS alert_id, a.received_at, a.symbol, a.event_type,
            a.source, a.trigger_price, a.message, a.raw_payload_json,
            n.risk_level, n.primary_driver, n.headline, n.memo_text,
            n.triage_json, n.metrics_json, n.knowledge_json
     FROM alerts a LEFT JOIN analyses n ON a.id = n.alert_id
     WHERE a.id = %d LIMIT 1;",
    as.integer(alert_id)
  )

  row <- DBI::dbGetQuery(conn, sql)
  if (nrow(row) == 0) return(NULL)

  list(
    alert = list(
      alert_id = row$alert_id[[1]],
      received_at = safe_time(row$received_at[[1]]),
      symbol = safe_chr(row$symbol[[1]], default = "SPY"),
      event_type = safe_chr(row$event_type[[1]], default = "watchlist_signal"),
      source = safe_chr(row$source[[1]], default = "unknown"),
      trigger_price = safe_num(row$trigger_price[[1]], default = NA_real_),
      message = safe_chr(row$message[[1]], default = "")
    ),
    raw_payload = parse_json_safely(row$raw_payload_json[[1]]),
    triage = parse_json_safely(row$triage_json[[1]]),
    risk = parse_json_safely(row$metrics_json[[1]]),
    knowledge = parse_json_safely(row$knowledge_json[[1]]),
    memo = list(
      headline = safe_chr(row$headline[[1]], default = ""),
      memo = safe_chr(row$memo_text[[1]], default = "")
    )
  )
}

fetch_latest_analysis <- function(symbol = NULL) {
  conn <- db_connect()
  on.exit(DBI::dbDisconnect(conn), add = TRUE)

  where_clause <- ""
  if (!is.null(symbol) && nzchar(safe_chr(symbol, default = ""))) {
    quoted_symbol <- DBI::dbQuoteString(conn, safe_chr(symbol))
    where_clause <- paste("WHERE a.symbol =", quoted_symbol)
  }

  sql <- glue::glue(
    "
    SELECT
      a.id AS alert_id,
      a.received_at,
      a.symbol,
      a.event_type,
      a.source,
      a.trigger_price,
      a.message,
      a.raw_payload_json,
      n.risk_level,
      n.primary_driver,
      n.headline,
      n.memo_text,
      n.triage_json,
      n.metrics_json,
      n.knowledge_json
    FROM alerts a
    LEFT JOIN analyses n ON a.id = n.alert_id
    {where_clause}
    ORDER BY a.id DESC
    LIMIT 1;
    "
  )

  row <- DBI::dbGetQuery(conn, sql)
  if (nrow(row) == 0) {
    return(NULL)
  }

  list(
    alert = list(
      alert_id = row$alert_id[[1]],
      received_at = safe_time(row$received_at[[1]]),
      symbol = safe_chr(row$symbol[[1]], default = "SPY"),
      event_type = safe_chr(row$event_type[[1]], default = "watchlist_signal"),
      source = safe_chr(row$source[[1]], default = "unknown"),
      trigger_price = safe_num(row$trigger_price[[1]], default = NA_real_),
      message = safe_chr(row$message[[1]], default = "")
    ),
    raw_payload = parse_json_safely(row$raw_payload_json[[1]]),
    triage = parse_json_safely(row$triage_json[[1]]),
    risk = parse_json_safely(row$metrics_json[[1]]),
    knowledge = parse_json_safely(row$knowledge_json[[1]]),
    memo = list(
      headline = safe_chr(row$headline[[1]], default = ""),
      memo = safe_chr(row$memo_text[[1]], default = "")
    )
  )
}
