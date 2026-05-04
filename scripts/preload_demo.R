source("R/paths.R")
library(dotenv)

.app_root <- find_app_root()
options(appv2.app_root = .app_root)
.env_path <- file.path(.app_root, ".env")
options(appv2.env_path = .env_path)

if (file.exists(.env_path)) {
  load_dot_env(.env_path)
}

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

ensure_runtime_state()

mode <- Sys.getenv("PRELOAD_DEMO_MODE", unset = "auto")
force <- identical(tolower(trimws(Sys.getenv("PRELOAD_DEMO_FORCE", unset = "false"))), "true")

result <- preload_demo_content(mode = mode, force = force)

print(result)
