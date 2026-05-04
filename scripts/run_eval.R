#!/usr/bin/env Rscript
# scripts/run_eval.R — produce data/eval/{v2,v3,comparison,summary,manual_scores_template}.csv
#
# Usage:
#   OPENAI_API_KEY=<your-openai-api-key>  Rscript scripts/run_eval.R [n_per_event]
#
# Default n_per_event = 1, giving 5 assets × 6 event types × 1 = 30 alerts.
# Each alert is run twice (V2-compat and V3) so total ~60 OpenAI passes.
# At gpt-4o-mini pricing this costs about $0.05 and takes ~5 minutes.

source("R/paths.R")
options(appv2.app_root = find_app_root())
.env_path <- file.path(getOption("appv2.app_root"), ".env")
options(appv2.env_path = .env_path)
if (file.exists(.env_path) &&
    requireNamespace("dotenv", quietly = TRUE)) {
  dotenv::load_dot_env(.env_path)
}

suppressMessages({
  library(shiny)     # for safe_chr-related env if any
  library(dplyr); library(glue); library(jsonlite); library(scales)
  library(tibble); library(quantmod); library(httr2); library(zoo)
  library(RSQLite); library(DBI); library(digest)
})

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
source("R/eval.R")

ensure_runtime_state()

args <- commandArgs(trailingOnly = TRUE)
n_per_event <- if (length(args) >= 1L) as.integer(args[[1L]]) else 1L

run_full_eval(n_per_event = n_per_event)
