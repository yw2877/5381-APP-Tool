# V3 Process Diagram

## Data Flow: Market Stress Copilot — Multi-Agent Risk Dashboard with Critic Loop

```mermaid
flowchart TD
    %% Input Layer
    A1([🖱️ Simulate Alert Button]):::input
    A2([📡 TradingView Webhook POST]):::input

    %% Ingestion
    B[Plumber Endpoint<br/>plumber/webhook.R<br/>returns 202 immediately]:::infra
    C[normalize_alert_payload<br/>Symbol · Event · Price · Timestamp]:::proc

    %% Storage 1
    D[(SQLite<br/>alerts table)]:::db

    %% LLM Gateway
    GW[R/llm.R · LLM Gateway<br/>retry · cache · schema validation · telemetry]:::gw

    %% Agent Pipeline with Critic Loop
    subgraph PIPE [" Multi-Agent Pipeline (R/pipeline.R) "]
        direction TB
        E["Agent 1 — Signal Triage<br/>──────────────<br/>LLM classifies event type"]:::agent
        F["Agent 2 — Risk Engine<br/>──────────────<br/>🛠️ Tool Calling<br/>VaR · Vol · Drawdown · Regime"]:::agent
        G["Agent 3 — Risk Memo<br/>──────────────<br/>📚 RAG-augmented<br/>headline · memo · action"]:::agent
        K{"Agent 4 — Critic<br/>──────────────<br/>5-dim score<br/>passes >= 0.75?"}:::critic
        L["Memo Agent (retry)<br/>with improvement_directives"]:::agent

        E --> F --> G --> K
        K -- "FAIL · iter < max" --> L
        L --> K
    end

    %% External
    MD[(Yahoo Finance<br/>quantmod · 5-min cache)]:::ext
    KB[(Knowledge Base<br/>terms · cases · playbook)]:::ext

    %% Storage 2
    H[(SQLite · analyses<br/>memo + status + iterations)]:::db
    I[(SQLite · agent_runs<br/>latency · tokens · retries · validation)]:::db
    J[(SQLite · quality_scores<br/>final_score · dimensions · history)]:::db

    %% Dashboard
    subgraph UI [" 5-Page Shiny Dashboard "]
        direction TB
        P1["Equities · Crypto<br/>KPI · TradingView · Quality Snapshot · Agents"]:::ui
        P2["Risk Overview<br/>Cross-asset table · Knowledge"]:::ui
        P3["Quality Dashboard<br/>📊 Pass rate · iterations · latency · errors · dimensions"]:::ui
        P4["Alert Log & Ops<br/>Raw payloads · agent traces · critic verdict · system status"]:::ui
    end

    %% Connections
    A1 --> B
    A2 --> B
    B  --> C
    C  --> D
    D  --> PIPE
    E  -. via .-> GW
    G  -. via .-> GW
    K  -. via .-> GW
    L  -. via .-> GW
    GW --> I
    MD -->|price history| F
    KB -->|retrieve context| G
    PIPE --> H
    K --> J
    H  --> UI
    I  --> P3
    J  --> P3
    J  --> P1

    %% Styles
    classDef input    fill:#d7f0df,stroke:#125631,color:#125631,font-weight:bold
    classDef infra    fill:#e8f0fe,stroke:#3367d6,color:#1a3a6e
    classDef proc     fill:#fff3e0,stroke:#e65100,color:#6d2a00
    classDef agent    fill:#fce4ec,stroke:#c2185b,color:#7b003e,text-align:left
    classDef critic   fill:#fff0c4,stroke:#a37200,color:#5d4100,font-weight:bold
    classDef gw       fill:#e1d5ff,stroke:#5a2ca0,color:#2d1462
    classDef db       fill:#ede7f6,stroke:#512da8,color:#2d1462
    classDef ext      fill:#e0f2f1,stroke:#00695c,color:#003d35
    classDef ui       fill:#e3f2fd,stroke:#0d47a1,color:#08245c
```

## V3 vs V2: what's new

| Aspect | V2 | V3 |
|---|---|---|
| Pipeline shape | Linear: Triage → Risk → Memo | **Loop**: Triage → Risk → Memo → Critic → (Memo retry) |
| Quality Control | None — every memo shipped as-is | Critic Agent scores every memo on 5 dimensions; loop regenerates if score < 0.75 |
| LLM error handling | `stop()` on first failure | Exponential-backoff retry · schema validation · degraded fallback |
| Telemetry | None | Per-call latency / tokens / retries / errors in `agent_runs` |
| Quality evidence | None | Quality Dashboard with 6 KPIs, time-series, dimension breakdown, iteration distribution, error rate |
| Webhook | Synchronous (blocks the response) | Returns 202, runs pipeline async via `later::later()` |
| Yahoo failure mode | Hard error | Stale-cache fallback with banner |
| Deployment | Shiny only | Shiny + webhook + shared SQLite volume + healthchecks |
| RAG context | Used once before memo | Same — but now the Critic checks that the memo actually cites the retrieved context |

## Component Summary

| Layer | Component | Technology |
|---|---|---|
| Input | Simulate / TradingView Webhook | Shiny + Plumber |
| Gateway | LLM call wrapper | `R/llm.R` (retry, cache, schema, telemetry) |
| Agent 1 | Signal Triage | OpenAI GPT (LLM classification) |
| Agent 2 | Risk Engine | Tool Calling → quantmod + custom R functions |
| Agent 3 | Risk Memo | RAG → local CSV/TXT knowledge base + retry-aware prompt |
| Agent 4 | Critic *(NEW)* | OpenAI GPT (5-dim quality scoring + improvement directives) |
| Storage | alerts · analyses · agent_runs · quality_scores | SQLite (volume-mounted in prod) |
| Market Data | Price history + risk metrics | Yahoo Finance via quantmod, 5-min cache, stale fallback |
| Frontend | 5-page dashboard | R Shiny + bslib + DT + plotly |
| Dashboard | Quality Dashboard *(NEW)* | Shiny + plotly box / bar / scatter / time-series |
| Deploy | Container orchestration | Docker Compose · Caddy · DigitalOcean droplet |
