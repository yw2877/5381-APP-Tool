# Troubleshooting

Symptom → likely cause → fix.

---

## App won't start

### "OPENAI_API_KEY is not configured"

The `.env` file is missing or `OPENAI_API_KEY` is blank.

```bash
ls -la .env                  # must exist
cat .env | grep OPENAI       # must have a non-empty value
# If missing, copy the template and fill it in:
cp .env.example .env
# then edit .env, set OPENAI_API_KEY=<your-openai-api-key>
```

The app will still boot in degraded mode (deterministic fallbacks); the
banner at the top of every page warns that OpenAI is unavailable.

### "No knowledge directory found"

`data/knowledge/` is missing. The repo ships with it; if you accidentally
deleted it:

```bash
git checkout origin/main -- data/knowledge
```

### "Could not connect to SQLite"

The data dir isn't writable. In Docker this means the volume isn't mounted:

```bash
docker compose down
docker compose up -d
docker exec msc-shiny ls -la /app/data
```

---

## Quality Dashboard is empty

You haven't simulated any alerts yet. Click **Simulate** on the Equities or
Crypto tab. Each click creates one row in `quality_scores`.

If you've simulated and still see nothing:

```bash
docker exec msc-shiny sqlite3 /app/data/alerts.sqlite \
  "SELECT COUNT(*) FROM quality_scores;"
```

If 0, the writer failed. Check logs:

```bash
docker compose logs shiny | grep -i 'record_quality_score'
```

---

## Memo always fails the Critic with low `factual_alignment`

Two common causes:

1. **Yahoo Finance is returning NA.** Open the Ops tab, select the alert,
   look at the Risk Metrics JSON. If most numbers are `null`, the risk block
   the Critic sees is empty so it can't verify factual alignment.

   Fix: check Yahoo connectivity from the droplet:
   ```bash
   docker exec msc-shiny Rscript -e \
     'library(quantmod); print(getSymbols("SPY", auto.assign=FALSE) |> tail(3))'
   ```

2. **The Memo Agent is hallucinating numbers.** Open the Memo tab, look at
   the body. If you see e.g. "VaR of 8%" but the structured risk block has
   `var_1d: 1.7%`, the Memo is making up numbers. Check that the system
   prompt is the current one (`docs/PROMPTS.md`); a stale prompt-hash cache
   can pin to an old version.

   Fix:
   ```r
   llm_clear_cache()
   ```

---

## Webhook returns 202 but no row appears in the dashboard

Async pipeline failed. The webhook accepts the alert and persists it to
`alerts`, but the `later::later()` call to run the agents threw. Check:

```bash
docker compose logs webhook | grep -i 'async pipeline failed'
```

Common cause: `OPENAI_API_KEY` not propagated to the webhook container.
`docker-compose.yml` sets it from the same `.env` as `shiny`.

---

## OpenAI 429 / rate limit

Backoff already retries 3 times. If they're all hitting 429:

- You're past your usage tier limit. Upgrade in the OpenAI dashboard.
- Or temporarily lower volume by setting `MAX_LOOP_ITERATIONS=1`.

---

## Yahoo Finance timeout

```
warning: Yahoo Finance fetch failed for SPY; using stale cache (12.3 min old)
```

This is the **stale-cache fallback** working as designed. The UI shows a
banner. If Yahoo is truly down, all assets will show stale data; metrics
will not update until Yahoo recovers.

Fix is to wait, or temporarily switch to a paid market-data provider. The
stale data is still better than no data — the existing memo is informative,
even if it lags real-time by 10 minutes.

---

## "Stuck loading" on TradingView chart

The TradingView iframe is blocked. Common causes:

- Browser ad-blocker (uBlock Origin can block `s.tradingview.com`)
- Restrictive corporate firewall
- Wrong `tv_symbol` in `R/config.R::APP_ASSETS`

Workaround: use the Price & Rolling Volatility chart on the same page —
that uses Yahoo Finance directly, no iframe.

---

## Container OOM-killed

The droplet ran out of memory. R + plotly + Yahoo data is ~700 MB resident.
With both Shiny and webhook containers running, you need at least 2 GB
free.

Fix:

- Resize to a 4 GB droplet (recommended)
- Or run only the Shiny container: `docker compose up -d shiny`

---

## SQLite locked

```
Error: database is locked
```

Two processes writing simultaneously. The `restart: unless-stopped` policy
in compose handles transient locks. If you see this consistently, switch
SQLite journal mode:

```bash
docker exec msc-shiny sqlite3 /app/data/alerts.sqlite "PRAGMA journal_mode=WAL;"
```

WAL mode allows concurrent readers + one writer. Persists across restarts.

---

## "ERR_TOO_MANY_REDIRECTS" via Caddy

Caddy is upgrading to HTTPS but the upstream (Shiny on port 3838) doesn't
trust Caddy. Add to your Caddyfile (replace `msc.example.com` with your
real hostname — example only):

```
msc.example.com {
    reverse_proxy localhost:3838 {
        header_up X-Forwarded-Proto {scheme}
    }
}
```

---

## Quality Dashboard charts don't render

Most likely a plotly/htmlwidgets version mismatch in the container. Rebuild:

```bash
docker compose build --no-cache shiny
docker compose up -d
```

If still broken, check the browser console (F12). Plotly errors usually
mean the data shape is wrong; look at:

```bash
docker exec msc-shiny sqlite3 /app/data/alerts.sqlite \
  "SELECT * FROM quality_scores LIMIT 3;"
```

---

## Eval harness runs forever

`scripts/run_eval.R` runs ~60 OpenAI calls. At 8 sec each that's 8 minutes.
If it stalls beyond 15 min, kill it (Ctrl-C) and run with `n_per_event = 1`
(default) instead of higher.

---

## Adding a new asset

`R/config.R` → append to `APP_ASSETS` tibble:

```r
APP_ASSETS <- tibble::tribble(
  ~label,    ~symbol,   ~tv_symbol,        ~asset_class, ~base_price, ~vol_scale,
  ...
  "AAPL",    "AAPL",    "NASDAQ:AAPL",     "Equity",     180,         0.020
)
```

Restart the app. The new symbol shows up in Asset dropdowns and the Risk
Overview table.

---

## Adding a new event type

`R/config.R` → append to `SIMULATED_EVENT_LIBRARY`:

```r
list(
  event_type = "rsi_overbought",
  message = "14-period RSI exceeded 80 with declining volume."
)
```

Then teach the simulator how to compute a synthetic trigger price for it
in `R/pipeline.R::simulation_reference_for_event()` and
`simulation_trigger_price()`.

The Critic will pick up the new event type automatically — the schema
allows any string in the alert payload's `event_type` field.
