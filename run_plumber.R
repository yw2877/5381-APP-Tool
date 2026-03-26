library(plumber)

source("appv2/R/config.R")

pr("appv2/plumber/webhook.R")$run(host = "0.0.0.0", port = APP_WEBHOOK_PORT)
