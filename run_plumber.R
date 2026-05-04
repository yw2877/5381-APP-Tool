library(plumber)

source("R/paths.R")
options(appv2.app_root = find_app_root())
.env_path <- file.path(getOption("appv2.app_root"), ".env")
options(appv2.env_path = .env_path)
if (file.exists(.env_path) &&
    requireNamespace("dotenv", quietly = TRUE)) {
  dotenv::load_dot_env(.env_path)
}

source("R/config.R")

port <- as.integer(Sys.getenv("APPV2_WEBHOOK_PORT", unset = APP_WEBHOOK_PORT))
pr("plumber/webhook.R")$run(host = "0.0.0.0", port = port)
