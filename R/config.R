APP_TITLE <- "Market Stress Copilot"
APP_SUBTITLE <- "TradingView-triggered multi-agent market risk warning system"

DEFAULT_LOOKBACK <- 120L

# ---------- paths ----------
# Detect working directory: works whether launched from repo root or parent
APP_ROOT <- if (file.exists("app.R")) "." else if (file.exists("5381-APP-Tool/app.R")) "5381-APP-Tool" else "."
APP_DB_PATH <- Sys.getenv("APPV2_DB_PATH", unset = file.path(APP_ROOT, "data", "alerts.sqlite"))
KNOWLEDGE_DIR <- file.path(APP_ROOT, "data", "knowledge")
PLAYBOOK_PATH <- file.path(KNOWLEDGE_DIR, "agent_playbook.txt")

# ---------- webhook ----------
TV_WEBHOOK_SECRET <- Sys.getenv("TV_WEBHOOK_SECRET", unset = "")
APP_WEBHOOK_PORT <- as.integer(Sys.getenv("APPV2_WEBHOOK_PORT", unset = "8000"))

# ---------- OpenAI ----------
OPENAI_API_KEY <- Sys.getenv("OPENAI_API_KEY", unset = "")
OPENAI_MODEL <- Sys.getenv("OPENAI_MODEL", unset = "gpt-4o-mini")

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
  )
)
