APP_TITLE <- "Market Stress Copilot"
APP_SUBTITLE <- "TradingView Signals + Multi-Agent Risk Dashboard"

DEFAULT_LOOKBACK <- 120L

# ---------- paths ----------
# Prefer root set in app.R (find_app_root); else cwd-based fallbacks for ad-hoc source()
APP_ROOT <- local({
  opt <- getOption("appv2.app_root")
  if (!is.null(opt) && nzchar(opt)) {
    normalizePath(opt, winslash = "/", mustWork = FALSE)
  } else if (file.exists("app.R")) {
    normalizePath(".", winslash = "/", mustWork = FALSE)
  } else if (file.exists("5381-APP-Tool/app.R")) {
    normalizePath("5381-APP-Tool", winslash = "/", mustWork = FALSE)
  } else {
    normalizePath(".", winslash = "/", mustWork = FALSE)
  }
})
APP_DB_PATH <- local({
  raw <- Sys.getenv("APPV2_DB_PATH", unset = "")
  if (nzchar(trimws(raw))) raw else file.path(APP_ROOT, "data", "alerts.sqlite")
})
KNOWLEDGE_DIR <- file.path(APP_ROOT, "data", "knowledge")
PLAYBOOK_PATH <- file.path(KNOWLEDGE_DIR, "agent_playbook.txt")

# ---------- webhook ----------
TV_WEBHOOK_SECRET <- Sys.getenv("TV_WEBHOOK_SECRET", unset = "")
APP_WEBHOOK_PORT <- as.integer(Sys.getenv("APPV2_WEBHOOK_PORT", unset = "8000"))

# ---------- OpenAI ----------
# Always read from the process environment (not a one-time copy at source time).
# If empty, reload .env once — some Shiny / IDE launch paths set env after config.R is parsed.
openai_key <- function() {
  k <- trimws(Sys.getenv("OPENAI_API_KEY", unset = ""))
  if (nzchar(k)) {
    return(k)
  }
  p <- getOption("appv2.env_path", default = "")
  if (nzchar(p) && file.exists(p) && requireNamespace("dotenv", quietly = TRUE)) {
    dotenv::load_dot_env(p)
    k <- trimws(Sys.getenv("OPENAI_API_KEY", unset = ""))
  }
  k
}

OPENAI_MODEL <- Sys.getenv("OPENAI_MODEL", unset = "gpt-4o-mini")

# ---------- V3: agentic loop + quality control ----------
# Critic agent decides whether the memo passes; if not, the loop regenerates
# the memo with critique feedback. These constants cap iterations and tune
# the gate.
QUALITY_THRESHOLD    <- as.numeric(Sys.getenv("QUALITY_THRESHOLD",    unset = "0.75"))
MAX_LOOP_ITERATIONS  <- as.integer(Sys.getenv("MAX_LOOP_ITERATIONS",  unset = "2"))

# LLM gateway settings (R/llm.R)
LLM_MAX_RETRIES      <- as.integer(Sys.getenv("LLM_MAX_RETRIES",      unset = "3"))
LLM_CACHE_TTL_MIN    <- as.integer(Sys.getenv("LLM_CACHE_TTL_MIN",    unset = "30"))
LLM_TIMEOUT_SECONDS  <- as.integer(Sys.getenv("LLM_TIMEOUT_SECONDS",  unset = "30"))

APP_ASSETS <- tibble::tribble(
  ~label,    ~symbol,   ~tv_symbol,        ~asset_class, ~base_price, ~vol_scale,
  "BTCUSDT", "BTC-USD", "BINANCE:BTCUSDT", "Crypto",     68000,       0.032,
  "ETHUSDT", "ETH-USD", "BINANCE:ETHUSDT", "Crypto",     3400,        0.030,
  "SPY",     "SPY",     "AMEX:SPY",        "ETF",        520,         0.012,
  "QQQ",     "QQQ",     "NASDAQ:QQQ",      "ETF",        445,         0.015,
  "NVDA",    "NVDA",    "NASDAQ:NVDA",     "Equity",     920,         0.024
)

LOOKBACK_CHOICES <- c("60D" = 60, "120D" = 120, "252D" = 252)

SIMULATED_EVENT_LIBRARY <- list(
  list(
    event_type = "bollinger_breakdown",
    message = "Price closed below the lower Bollinger band after two failed rebounds."
  ),
  list(
    event_type = "atr_expansion",
    message = "ATR expanded sharply versus the previous 20 bars and range is widening."
  ),
  list(
    event_type = "death_cross_volume",
    message = "Fast moving average crossed below slow moving average while volume accelerated."
  ),
  list(
    event_type = "break_prior_low",
    message = "Price broke the prior swing low and failed to reclaim it on the next bar."
  ),
  list(
    event_type = "support_break",
    message = "Price slipped below a nearby support zone and failed to recover it."
  ),
  list(
    event_type = "resistance_break",
    message = "Price pushed through a nearby resistance zone with follow-through buying."
  )
)
