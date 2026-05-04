source("R/paths.R")
library(dotenv)

.app_root <- find_app_root()
options(appv2.app_root = .app_root)
.env_path <- file.path(.app_root, ".env")
options(appv2.env_path = .env_path)

if (!file.exists(.env_path)) {
  warning(
    "No .env at ", .env_path, " (getwd() = ", getwd(), "). ",
    "Set environment variable APPV2_ROOT to the repo folder, or open/run the app from that folder.",
    call. = FALSE
  )
} else {
  load_dot_env(.env_path)
}

# If ~/.Rprofile sets warn=2, harmless "built under R x.y.z" package warnings become fatal
options(warn = 1)

library(shiny)
library(bslib)
library(DT)
library(dplyr)
library(glue)
library(jsonlite)
library(scales)
library(htmltools)
library(quantmod)
library(httr2)
library(plotly)
library(zoo)
library(RSQLite)
library(DBI)
library(tibble)
library(digest)

source("R/config.R")
source("R/helpers.R")
source("R/schemas.R")
source("R/quality.R")
source("R/storage.R")
source("R/knowledge.R")
source("R/market_data.R")
source("R/llm.R")
source("R/agents.R")
source("R/pipeline.R")
source("R/ui.R")
source("R/server.R")

ensure_runtime_state()
if (isTRUE(PRELOAD_DEMO_ON_BOOT)) {
  try(preload_demo_content(mode = PRELOAD_DEMO_MODE), silent = TRUE)
}

# Pre-warm the in-process market data cache before accepting connections.
# This runs once per worker so subsequent sessions hit the cache (5-min TTL)
# instead of blocking on live Yahoo Finance network calls.
local({
  message("[startup] Pre-warming market data cache...")
  for (.sym in APP_ASSETS$label) {
    tryCatch(
      get_price_history(.sym, lookback = DEFAULT_LOOKBACK),
      error = function(e) message("[warn] price warm-up failed for ", .sym, ": ", e$message)
    )
  }
  # SPY at lookback=65 is the benchmark used by correlation_jump internally
  tryCatch(
    get_price_history("SPY", lookback = 65L),
    error = function(e) message("[warn] SPY_65 warm-up failed: ", e$message)
  )
  message("[startup] Market data cache ready.")
})

shinyApp(ui = app_ui(), server = app_server)
