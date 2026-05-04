db_connect <- function() {
  conn <- DBI::dbConnect(RSQLite::SQLite(), APP_DB_PATH)
  try(DBI::dbExecute(conn, "PRAGMA busy_timeout = 5000;"), silent = TRUE)
  try(DBI::dbExecute(conn, "PRAGMA foreign_keys = ON;"), silent = TRUE)
  conn
}

ensure_table_column <- function(conn, table_name, column_name, column_type) {
  info <- DBI::dbGetQuery(conn, sprintf("PRAGMA table_info(%s);", table_name))
  if (!column_name %in% info$name) {
    DBI::dbExecute(
      conn,
      sprintf(
        "ALTER TABLE %s ADD COLUMN %s %s;",
        table_name,
        column_name,
        column_type
      )
    )
  }
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

  # WAL reduces reader/writer contention between the Shiny app and webhook.
  try(DBI::dbExecute(conn, "PRAGMA journal_mode = WAL;"), silent = TRUE)
  try(DBI::dbExecute(conn, "PRAGMA synchronous = NORMAL;"), silent = TRUE)

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
      "reference_type TEXT,",
      "reference_level REAL,",
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
      "recommended_action TEXT,",
      "triage_json TEXT,",
      "metrics_json TEXT,",
      "knowledge_json TEXT,",
      "FOREIGN KEY(alert_id) REFERENCES alerts(id)",
      ");"
    )
  )

  ensure_table_column(conn, "alerts", "reference_type", "TEXT")
  ensure_table_column(conn, "alerts", "reference_level", "REAL")
  ensure_table_column(conn, "analyses", "recommended_action", "TEXT")

  # ---------- V3 telemetry / quality tables ----------
  DBI::dbExecute(
    conn,
    paste(
      "CREATE TABLE IF NOT EXISTS agent_runs (",
      "id INTEGER PRIMARY KEY AUTOINCREMENT,",
      "alert_id INTEGER,",
      "agent_name TEXT NOT NULL,",
      "iteration INTEGER DEFAULT 1,",
      "started_at TEXT NOT NULL,",
      "finished_at TEXT NOT NULL,",
      "latency_ms INTEGER,",
      "prompt_tokens INTEGER,",
      "completion_tokens INTEGER,",
      "n_retries INTEGER,",
      "cache_hit INTEGER,",
      "validation_passed INTEGER,",
      "error_class TEXT,",
      "error_message TEXT,",
      "prompt_hash TEXT,",
      "model TEXT",
      ");"
    )
  )
  DBI::dbExecute(conn,
    "CREATE INDEX IF NOT EXISTS idx_agent_runs_alert  ON agent_runs(alert_id);")
  DBI::dbExecute(conn,
    "CREATE INDEX IF NOT EXISTS idx_agent_runs_agent  ON agent_runs(agent_name);")
  DBI::dbExecute(conn,
    "CREATE INDEX IF NOT EXISTS idx_agent_runs_time   ON agent_runs(started_at);")

  DBI::dbExecute(
    conn,
    paste(
      "CREATE TABLE IF NOT EXISTS quality_scores (",
      "alert_id INTEGER PRIMARY KEY,",
      "final_score REAL,",
      "passed INTEGER,",
      "iterations_used INTEGER,",
      "clarity REAL,",
      "completeness REAL,",
      "actionability REAL,",
      "factual_alignment REAL,",
      "tone REAL,",
      "iteration_history_json TEXT,",
      "degraded INTEGER DEFAULT 0,",
      "created_at TEXT NOT NULL,",
      "FOREIGN KEY(alert_id) REFERENCES alerts(id)",
      ");"
    )
  )

  # extend analyses with status + quality flag for partial pipelines
  ensure_table_column(conn, "analyses", "status", "TEXT")
  ensure_table_column(conn, "analyses", "iterations_used", "INTEGER")
  ensure_table_column(conn, "analyses", "final_quality_score", "REAL")
  ensure_table_column(conn, "analyses", "quality_passed", "INTEGER")

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
    reference_type = safe_chr(alert$reference_type, default = ""),
    reference_level = safe_num(alert$reference_level, default = NA_real_),
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

save_analysis_record <- function(alert_id, analysis, status = "ok") {
  conn <- db_connect()
  on.exit(DBI::dbDisconnect(conn), add = TRUE)

  DBI::dbExecute(
    conn,
    sprintf("DELETE FROM analyses WHERE alert_id = %d;", as.integer(alert_id))
  )

  quality <- analysis$quality %||% list()

  row <- tibble::tibble(
    alert_id = as.integer(alert_id),
    created_at = format_ts(Sys.time()),
    risk_level = safe_chr(analysis$risk$risk_level, default = "monitor"),
    primary_driver = safe_chr(analysis$risk$primary_driver, default = "baseline"),
    headline = safe_chr(analysis$memo$headline, default = ""),
    memo_text = safe_chr(analysis$memo$memo, default = ""),
    recommended_action = safe_chr(analysis$memo$recommended_action, default = ""),
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
    ),
    status = safe_chr(status, default = "ok"),
    iterations_used = as.integer(quality$iterations_used %||% NA_integer_),
    final_quality_score = safe_num(quality$final_score, default = NA_real_),
    quality_passed = as.integer(isTRUE(quality$passed))
  )

  DBI::dbWriteTable(conn, "analyses", row, append = TRUE)
  invisible(alert_id)
}

# ---------- V3: agent run telemetry ----------
record_agent_run <- function(alert_id, agent_name, iteration = 1L,
                             started_at, finished_at,
                             latency_ms = NA_integer_,
                             prompt_tokens = NA_integer_,
                             completion_tokens = NA_integer_,
                             n_retries = 0L,
                             cache_hit = FALSE,
                             validation_passed = TRUE,
                             error_class = NA_character_,
                             error_message = NA_character_,
                             prompt_hash = NA_character_,
                             model = NA_character_) {
  tryCatch({
    conn <- db_connect()
    on.exit(DBI::dbDisconnect(conn), add = TRUE)

    row <- tibble::tibble(
      alert_id          = if (is.null(alert_id)) NA_integer_ else as.integer(alert_id),
      agent_name        = safe_chr(agent_name, default = "unknown"),
      iteration         = as.integer(iteration),
      started_at        = format_ts(started_at),
      finished_at       = format_ts(finished_at),
      latency_ms        = as.integer(latency_ms),
      prompt_tokens     = as.integer(prompt_tokens),
      completion_tokens = as.integer(completion_tokens),
      n_retries         = as.integer(n_retries),
      cache_hit         = as.integer(isTRUE(cache_hit)),
      validation_passed = as.integer(isTRUE(validation_passed)),
      error_class       = safe_chr(error_class, default = NA_character_),
      error_message     = safe_chr(error_message, default = NA_character_),
      prompt_hash       = safe_chr(prompt_hash, default = NA_character_),
      model             = safe_chr(model, default = NA_character_)
    )

    DBI::dbWriteTable(conn, "agent_runs", row, append = TRUE)
    invisible(TRUE)
  }, error = function(e) {
    # Telemetry must never break the pipeline.
    message("record_agent_run: ", conditionMessage(e))
    invisible(FALSE)
  })
}

record_quality_score <- function(alert_id, quality) {
  if (is.null(quality)) return(invisible(FALSE))

  tryCatch({
    conn <- db_connect()
    on.exit(DBI::dbDisconnect(conn), add = TRUE)

    DBI::dbExecute(
      conn,
      sprintf("DELETE FROM quality_scores WHERE alert_id = %d;",
              as.integer(alert_id))
    )

    dim <- quality$dimension_scores %||% list()

    row <- tibble::tibble(
      alert_id          = as.integer(alert_id),
      final_score       = safe_num(quality$final_score,    default = NA_real_),
      passed            = as.integer(isTRUE(quality$passed)),
      iterations_used   = as.integer(quality$iterations_used %||% NA_integer_),
      clarity           = safe_num(dim$clarity,           default = NA_real_),
      completeness      = safe_num(dim$completeness,      default = NA_real_),
      actionability     = safe_num(dim$actionability,     default = NA_real_),
      factual_alignment = safe_num(dim$factual_alignment, default = NA_real_),
      tone              = safe_num(dim$tone,              default = NA_real_),
      iteration_history_json = jsonlite::toJSON(
        quality$iteration_history %||% list(),
        auto_unbox = TRUE,
        null = "null"
      ),
      degraded   = as.integer(isTRUE(quality$degraded)),
      created_at = format_ts(Sys.time())
    )

    DBI::dbWriteTable(conn, "quality_scores", row, append = TRUE)
    invisible(TRUE)
  }, error = function(e) {
    message("record_quality_score: ", conditionMessage(e))
    invisible(FALSE)
  })
}

fetch_agent_runs_for_alert <- function(alert_id) {
  if (is.null(alert_id) || length(alert_id) == 0 ||
      !is.finite(suppressWarnings(as.integer(alert_id[[1]])))) {
    return(data.frame())
  }
  conn <- db_connect()
  on.exit(DBI::dbDisconnect(conn), add = TRUE)
  sql <- sprintf(
    "SELECT * FROM agent_runs WHERE alert_id = %d
     ORDER BY id ASC;",
    as.integer(alert_id))
  DBI::dbGetQuery(conn, sql)
}

fetch_agent_runs <- function(since = NULL, limit = 1000L) {
  conn <- db_connect()
  on.exit(DBI::dbDisconnect(conn), add = TRUE)

  where_clause <- ""
  if (!is.null(since)) {
    quoted <- DBI::dbQuoteString(conn, format_ts(since))
    where_clause <- paste("WHERE started_at >=", quoted)
  }
  sql <- glue::glue(
    "SELECT * FROM agent_runs {where_clause}
     ORDER BY id DESC LIMIT {as.integer(limit)};"
  )
  DBI::dbGetQuery(conn, sql)
}

fetch_quality_scores <- function(since = NULL, limit = 1000L) {
  conn <- db_connect()
  on.exit(DBI::dbDisconnect(conn), add = TRUE)

  where_clause <- ""
  if (!is.null(since)) {
    quoted <- DBI::dbQuoteString(conn, format_ts(since))
    where_clause <- paste("WHERE q.created_at >=", quoted)
  }
  sql <- glue::glue(
    "SELECT q.*, a.symbol, a.event_type, n.headline
     FROM quality_scores q
     LEFT JOIN alerts   a ON q.alert_id = a.id
     LEFT JOIN analyses n ON q.alert_id = n.alert_id
     {where_clause}
     ORDER BY q.created_at DESC LIMIT {as.integer(limit)};"
  )
  DBI::dbGetQuery(conn, sql)
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
      a.reference_type,
      a.reference_level,
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

count_alert_history <- function() {
  conn <- db_connect()
  on.exit(DBI::dbDisconnect(conn), add = TRUE)
  DBI::dbGetQuery(conn, "SELECT COUNT(*) AS n FROM alerts;")$n[[1]]
}

# Classify analysis state for an alerts/analyses LEFT JOIN row.
# "pending"  — async pipeline hasn't written analyses yet (no triage, no headline)
# "partial"  — some agents fired but not all (e.g. triage saved, memo failed)
# "complete" — full pipeline output present
.classify_analysis_status <- function(triage, memo_headline) {
  has_triage <- !is.null(triage)
  has_memo   <- nzchar(safe_chr(memo_headline, default = ""))
  if (!has_triage && !has_memo) return("pending")
  if (!has_triage ||  !has_memo) return("partial")
  "complete"
}

fetch_analysis_by_id <- function(alert_id) {
  conn <- db_connect()
  on.exit(DBI::dbDisconnect(conn), add = TRUE)

  sql <- sprintf(
    "SELECT a.id AS alert_id, a.received_at, a.symbol, a.event_type,
            a.source, a.trigger_price, a.reference_type, a.reference_level,
            a.message, a.raw_payload_json,
            n.risk_level, n.primary_driver, n.headline, n.memo_text,
            n.recommended_action,
            n.triage_json, n.metrics_json, n.knowledge_json
     FROM alerts a LEFT JOIN analyses n ON a.id = n.alert_id
     WHERE a.id = %d LIMIT 1;",
    as.integer(alert_id)
  )

  row <- DBI::dbGetQuery(conn, sql)
  if (nrow(row) == 0) return(NULL)

  triage_parsed <- parse_json_safely(row$triage_json[[1]])
  memo_headline <- safe_chr(row$headline[[1]], default = "")

  list(
    alert = list(
      alert_id = row$alert_id[[1]],
      received_at = safe_time(row$received_at[[1]]),
      symbol = safe_chr(row$symbol[[1]], default = "SPY"),
      event_type = safe_chr(row$event_type[[1]], default = "watchlist_signal"),
      source = safe_chr(row$source[[1]], default = "unknown"),
      trigger_price = safe_num(row$trigger_price[[1]], default = NA_real_),
      reference_type = safe_chr(row$reference_type[[1]], default = ""),
      reference_level = safe_num(row$reference_level[[1]], default = NA_real_),
      message = safe_chr(row$message[[1]], default = "")
    ),
    raw_payload = parse_json_safely(row$raw_payload_json[[1]]),
    triage = triage_parsed,
    risk = parse_json_safely(row$metrics_json[[1]]),
    knowledge = parse_json_safely(row$knowledge_json[[1]]),
    memo = list(
      headline = memo_headline,
      memo = safe_chr(row$memo_text[[1]], default = ""),
      recommended_action = safe_chr(row$recommended_action[[1]], default = "")
    ),
    status = .classify_analysis_status(triage_parsed, memo_headline)
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
      a.reference_type,
      a.reference_level,
      a.message,
      a.raw_payload_json,
      n.risk_level,
      n.primary_driver,
      n.headline,
      n.memo_text,
      n.recommended_action,
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

  triage_parsed <- parse_json_safely(row$triage_json[[1]])
  memo_headline <- safe_chr(row$headline[[1]], default = "")

  list(
    alert = list(
      alert_id = row$alert_id[[1]],
      received_at = safe_time(row$received_at[[1]]),
      symbol = safe_chr(row$symbol[[1]], default = "SPY"),
      event_type = safe_chr(row$event_type[[1]], default = "watchlist_signal"),
      source = safe_chr(row$source[[1]], default = "unknown"),
      trigger_price = safe_num(row$trigger_price[[1]], default = NA_real_),
      reference_type = safe_chr(row$reference_type[[1]], default = ""),
      reference_level = safe_num(row$reference_level[[1]], default = NA_real_),
      message = safe_chr(row$message[[1]], default = "")
    ),
    raw_payload = parse_json_safely(row$raw_payload_json[[1]]),
    triage = triage_parsed,
    risk = parse_json_safely(row$metrics_json[[1]]),
    knowledge = parse_json_safely(row$knowledge_json[[1]]),
    memo = list(
      headline = memo_headline,
      memo = safe_chr(row$memo_text[[1]], default = ""),
      recommended_action = safe_chr(row$recommended_action[[1]], default = "")
    ),
    status = .classify_analysis_status(triage_parsed, memo_headline)
  )
}
