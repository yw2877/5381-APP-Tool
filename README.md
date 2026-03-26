# Market Stress Copilot (`appv2`)

Single-page Shiny scaffold for a TradingView-driven multi-agent risk warning app.

## Included

- Single-page `Shiny` UI
- `plumber` webhook endpoint for TradingView alerts
- SQLite persistence for alerts and analysis snapshots
- Three agent stubs:
  - `Signal Triage Agent`
  - `Risk Engine Agent`
  - `Risk Memo Agent`
- Local RAG seed files in `data/knowledge/`
- Simulated alert button so the app is demo-able before the real webhook is wired

## Run The Shiny App

```r
shiny::runApp("appv2")
```

## Run The Webhook Service

```r
source("appv2/run_plumber.R")
```

Or:

```r
plumber::pr("appv2/plumber/webhook.R")$run(host = "0.0.0.0", port = 8000)
```

## TradingView Wiring

Point your TradingView alert webhook to:

```text
POST http://<your-host>:8000/tv-alert
```

Expected JSON shape:

```json
{
  "symbol": "BTCUSDT",
  "event_type": "bollinger_breakdown",
  "source": "tradingview",
  "trigger_price": 67210.5,
  "message": "Price closed below lower Bollinger band.",
  "timestamp": "2026-03-26 16:10:00 EDT"
}
```

Optional security header:

```text
X-TV-SECRET: <your-secret>
```

Set `TV_WEBHOOK_SECRET` in the environment to enforce it.

## Swap In Real Market Data

The current scaffold uses deterministic mock price paths in `R/market_data.R`.

Replace:

- `get_price_history()`

with your real data adapter once your TradingView or market-data plumbing is ready.

## Suggested Deployment Split

- Deploy `appv2/` as the Shiny app
- Deploy `plumber/webhook.R` as a small API service
- Keep both pointing at the same SQLite replacement later if you move to Postgres or Supabase
