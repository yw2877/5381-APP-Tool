# Market Stress Copilot

> A multi-agent risk dashboard that turns a noisy market alert into a 30-second
> executive briefing — with an automatic quality gate.

> ⚠️ **LIVE URL REQUIRED BEFORE SUBMISSION** — replace the `<TODO_LIVE_URL>`
> placeholders below with the real DigitalOcean URL **and** update
> `docs/SLIDES.md`, `docs/SUBMISSION.md` accordingly. Search the repo for
> `<TODO_LIVE_URL>` to find every spot.

**🌐 Live demo:** `<TODO_LIVE_URL>`  ·
**📊 Quality Dashboard:** `<TODO_LIVE_URL>/?tab=Quality`  ·
**🩺 Webhook health:** `<TODO_WEBHOOK_URL>/health`

[![R Shiny](https://img.shields.io/badge/R-Shiny-blue)](https://shiny.posit.co/)
[![Deployed on DigitalOcean](https://img.shields.io/badge/deployed-DigitalOcean-0080ff)](https://www.digitalocean.com/)
[![SYSEN 5381](https://img.shields.io/badge/SYSEN-5381-B31B1B)](https://www.cornell.edu/)

---

## What this is

A four-agent Shiny dashboard that ingests a market alert (live TradingView
webhook, or a Simulate button), retrieves real Yahoo Finance prices, computes
risk metrics, and produces a short executive memo — then **scores its own
output** and re-writes when the score is too low.

Three personas use it:

| Persona | What they need | Where it shows up |
|---|---|---|
| **Trader** | "Should I act on this alert in the next 60 seconds?" | Memo headline + recommended action |
| **Risk Officer** | "Does this match a prior stress episode?" | Memo + matched historical cases + critic critique |
| **Quant / SRE** | "Is the AI system itself working?" | Quality Dashboard + telemetry + agent traces |

---

## The four agents (V3)

```
Alert ─▶ Triage ─▶ Risk Engine ─▶ Memo ─▶ Critic ──┐
                                    ▲              │
                                    └─ retry ──────┘
                                       (max 2x)
```

| Agent | Role | Tech |
|---|---|---|
| **Signal Triage** | Classifies the signal (`trend_break`, `volatility_spike`, …) and proposes what to monitor. | OpenAI · `gpt-4o-mini` · ~400 tokens |
| **Risk Engine** | Computes deterministic risk metrics (20D vol, VaR, ES, drawdown, regime score) from real Yahoo Finance prices. **Tool-calling component** — no LLM. | quantmod + custom R |
| **Risk Memo** | Writes a 100-1500 char executive memo. **RAG-augmented** with a local risk-term + historical-case + playbook knowledge base. Re-runs with critic feedback if rejected. | OpenAI · ~700 tokens |
| **Critic** *(NEW in V3)* | Scores the memo on five dimensions (clarity, completeness, actionability, factual alignment, tone). If `score < 0.75`, sends improvement directives back to the Memo Agent. | OpenAI · ~500 tokens |

The Critic is the V3 centerpiece — it provides both the **agentic loop** and the
**quality control evidence** the assignment requires.

📐 [Architecture diagram](docs/process_diagram.md) ·
📝 [Full prompt registry](docs/PROMPTS.md)

---

## Quality control

| Layer | Where it lives | What it does |
|---|---|---|
| Schema validation | `R/schemas.R` + `R/llm.R` | Every LLM response is validated against a schema. Schema-repair retry on first failure. |
| Range guardrails  | `R/quality.R`  | Risk metrics are clipped to plausible ranges (e.g. `var_1d ∈ [0, 1]`); flagged for the Critic. |
| Retry             | `R/llm.R`     | Exponential backoff on 429/5xx/timeout. Max 3 attempts. |
| Prompt cache      | `R/llm.R`     | Hash-keyed in-memory cache (30-min TTL). Same input → no API call. |
| Telemetry         | `agent_runs` SQLite table | Latency, tokens, retries, validation status — every call. |
| Quality scoring   | `quality_scores` SQLite table | Critic verdict, dimension scores, iteration history. |
| Degraded fallback | `R/agents.R` + `R/quality.R` | If OpenAI is down, deterministic fallback memos fire and the UI shows a warning banner. |
| Quality Dashboard | `page_quality_dashboard()` | Six KPIs + four plotly charts surfacing all of the above. |

📊 [Evaluation results — V2 vs V3 numbers](docs/EVAL_RESULTS.md) ·
🎤 [Presentation](docs/presentation.html) (open in browser)

---

## Quickstart

### Local (with R installed)

```bash
git clone https://github.com/yw2877/5381-APP-Tool.git
cd 5381-APP-Tool

# 1. Copy the env template and fill in your real OpenAI key.
cp .env.example .env
# then edit .env, set OPENAI_API_KEY=<your-openai-api-key>

# 2. Install R packages
Rscript -e 'install.packages(c("shiny","bslib","DT","dplyr","glue","jsonlite","scales","htmltools","quantmod","httr2","plotly","zoo","RSQLite","DBI","tibble","dotenv","digest","plumber","later","future","furrr"))'

# 3. Run the Shiny app
Rscript -e 'shiny::runApp(".", port=3838, launch.browser=TRUE)'
```

Open `http://localhost:3838`, dismiss the welcome modal, click **Simulate**.

### Local (Docker Compose)

```bash
cp .env.example .env
# edit .env, set OPENAI_API_KEY=<your-openai-api-key>
docker compose up --build
```

- Shiny: `http://localhost:3838`
- Webhook + health: `http://localhost:8000/health`
- Persistent SQLite via the `sqlite-data` named volume.

### Cloud (DigitalOcean)

The `main` branch auto-deploys to our DigitalOcean droplet. To set up your own:

```bash
# On a fresh Ubuntu droplet:
git clone https://github.com/yw2877/5381-APP-Tool.git
cd 5381-APP-Tool
cp .env.example .env
# edit .env, set OPENAI_API_KEY=<your-openai-api-key>
docker compose up -d
# (then put Caddy in front for HTTPS — see docs/RUNBOOK.md)
```

Detailed deployment runbook: [`docs/RUNBOOK.md`](docs/RUNBOOK.md).

---

## TradingView wiring

Point your TradingView alert webhook to:

```
POST http://<your-host>:8000/tv-alert
Content-Type: application/json
X-TV-SECRET: <your-secret>     (only required if TV_WEBHOOK_SECRET is set)

{
  "symbol": "BTCUSDT",
  "event_type": "bollinger_breakdown",
  "source": "tradingview",
  "trigger_price": 67210.5,
  "message": "Price closed below lower Bollinger band.",
  "timestamp": "2026-03-26 16:10:00 EDT"
}
```

The webhook returns `202 Accepted` immediately; the agent pipeline runs
asynchronously and the result appears on the dashboard within ~10 seconds.

---

## Configuration

| Env var | Default | What it does |
|---|---|---|
| `OPENAI_API_KEY` | _(required)_ | Your OpenAI API key. Without it, the app runs in degraded mode. |
| `OPENAI_MODEL` | `gpt-4o-mini` | Model used by Triage, Memo, Critic. |
| `QUALITY_THRESHOLD` | `0.75` | Minimum Critic score for a memo to pass. |
| `MAX_LOOP_ITERATIONS` | `2` | Hard cap on memo regenerations. |
| `LLM_MAX_RETRIES` | `3` | Retries on transient OpenAI errors. |
| `LLM_CACHE_TTL_MIN` | `30` | Prompt-hash cache TTL in minutes. |
| `TV_WEBHOOK_SECRET` | _(empty)_ | If set, `/tv-alert` requires `X-TV-SECRET` header. |
| `APPV2_DB_PATH` | `data/alerts.sqlite` | SQLite path. Set to a mounted volume in production. |
| `HOST_PORT` / `WEBHOOK_PORT` | 3838 / 8000 | Compose-only port mappings. |

---

## File structure

```
5381-APP-Tool/
├── app.R                  Shiny entry point
├── run_plumber.R          Webhook entry point
├── Dockerfile             Single image for both services
├── docker-compose.yml     Two-service deploy (shiny + webhook + shared volume)
├── R/
│   ├── config.R           constants, env, asset library
│   ├── helpers.R          safe_chr, format_pct, …
│   ├── schemas.R          (V3) JSON schemas for every agent output
│   ├── quality.R          (V3) range guardrails + degraded critique
│   ├── storage.R          SQLite: alerts, analyses, agent_runs, quality_scores
│   ├── knowledge.R        RAG retrieval (keyword scoring)
│   ├── market_data.R      Yahoo Finance + risk metrics + stale-cache fallback
│   ├── llm.R              (V3) LLM gateway: retry, cache, schema, telemetry
│   ├── agents.R           4 agents: Triage, Risk Engine, Memo, Critic
│   ├── pipeline.R         (V3) agentic loop orchestrator
│   ├── ui.R               5 nav pages (incl. Quality Dashboard)
│   ├── server.R           Shiny server logic
│   └── eval.R             (V3) Before/After eval harness
├── plumber/
│   └── webhook.R          /tv-alert + /health + /metrics
├── scripts/
│   └── run_eval.R         CLI entry: produce data/eval/*.csv
├── data/
│   ├── alerts.sqlite      created on first run
│   └── knowledge/
│       ├── risk_terms.csv
│       ├── historical_cases.csv
│       └── agent_playbook.txt
├── www/styles.css
└── docs/
    ├── process_diagram.md / .png
    ├── PROMPTS.md         (V3) full system prompts for every agent
    ├── RUNBOOK.md         (V3) DO + Caddy + backup + rotate keys
    ├── TROUBLESHOOTING.md (V3) symptom → cause → fix
    ├── SLIDES.md          (V3) presentation outline + demo script
    └── core_changes_log.md
```

---

## Stakeholder value

We didn't ship features for their own sake. Each piece maps to a real
question a desk asks:

| Stakeholder question | Component |
|---|---|
| "What just happened?" | Triage classification + memo headline |
| "How risky is this asset right now?" | Risk Engine metrics + KPI strip + risk pill |
| "Has this happened before?" | RAG-retrieved historical cases (asset-first) |
| "What should I do in the next minute?" | Memo `recommended_action` |
| "Can I trust this AI?" | Quality Dashboard: pass rate, dimension scores, latency |
| "Did the system catch its own bad output?" | Iteration distribution + critic critique |
| "Is the system itself healthy?" | `/health` endpoint + System Status card |

---

## Limitations

- Yahoo Finance data is delayed by ~15 minutes. Don't trade off this dashboard
  alone.
- The RAG knowledge base is small (6 risk terms + 8 historical cases). It's
  illustrative, not exhaustive.
- Critic is itself an LLM, so its scores have inherent noise. We mitigate with
  deterministic schema guardrails; we don't claim ground truth.
- gpt-4o-mini was chosen for cost/latency. The `OPENAI_MODEL` env var lets you
  swap to a heavier model.

---

## Team & roles

> Replace each `<TODO_NAME>` with the actual team member name before submission.

- 🧪 **Project Manager** — `<TODO_NAME>` — system architecture, integration, deployment
- 🤖 **Agent Orchestration Engineer** — `<TODO_NAME>` — Triage / Memo / Critic prompts + loop
- 🔌 **Backend Developer** — `<TODO_NAME>` — webhook, storage, telemetry
- 🎨 **Frontend Developer** — `<TODO_NAME>` — Shiny UI, Quality Dashboard, persona-aware panels
- 📊 **Data Engineer** — `<TODO_NAME>` — risk metrics, knowledge base, RAG retrieval
- 🚀 **DevOps Engineer** — `<TODO_NAME>` — Docker, DigitalOcean deploy, healthchecks

---

## Course

Built for **Cornell SYSEN 5381 — Data Science and AI for Systems Engineering**,
Tools 1 → 2 → 3.
