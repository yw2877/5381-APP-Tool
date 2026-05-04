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

shinyApp(ui = app_ui(), server = app_server)
