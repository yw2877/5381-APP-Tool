# plumber::pr("appv2/plumber/webhook.R")$run(port = 8000)

source("appv2/R/config.R")
source("appv2/R/helpers.R")
source("appv2/R/storage.R")
source("appv2/R/knowledge.R")
source("appv2/R/market_data.R")
source("appv2/R/agents.R")
source("appv2/R/pipeline.R")

ensure_runtime_state()

#* @apiTitle Market Stress Copilot Webhook

validate_webhook_secret <- function(req) {
  if (!nzchar(TV_WEBHOOK_SECRET)) {
    return(TRUE)
  }

  provided <- req$HTTP_X_TV_SECRET %||% req$HTTP_X_WEBHOOK_SECRET %||% ""
  identical(safe_chr(provided, default = ""), TV_WEBHOOK_SECRET)
}

#* Health check
#* @get /health
function() {
  list(
    ok = TRUE,
    app = APP_TITLE,
    db_path = APP_DB_PATH
  )
}

#* Receive TradingView alert payloads
#* @post /tv-alert
#* @serializer json list(auto_unbox = TRUE)
function(req, res) {
  if (!validate_webhook_secret(req)) {
    res$status <- 401
    return(list(ok = FALSE, error = "invalid webhook secret"))
  }

  payload <- tryCatch(
    jsonlite::fromJSON(req$postBody, simplifyVector = FALSE),
    error = function(e) {
      list(
        symbol = "SPY",
        event_type = "malformed_payload",
        source = "webhook",
        message = paste("Webhook payload could not be parsed:", e$message)
      )
    }
  )

  result <- process_and_store_alert(payload, lookback = DEFAULT_LOOKBACK)

  list(
    ok = TRUE,
    alert_id = result$alert_id,
    symbol = result$analysis$alert$symbol,
    risk_level = result$analysis$risk$risk_level,
    signal_type = result$analysis$triage$signal_type
  )
}
