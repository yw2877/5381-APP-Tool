# App V2 Process Diagram

## Data Flow: TradingView Multi-Agent Risk Dashboard

```mermaid
flowchart TD
    %% Input Layer
    A1([🖱️ Simulate Alert Button]):::input
    A2([📡 TradingView Webhook POST]):::input

    %% Ingestion
    B[Plumber Endpoint\nwebhook.R]:::infra
    C[normalize_alert_payload\nSymbol · Event Type · Price · Timestamp]:::proc

    %% Storage 1
    D[(SQLite\nalerts table)]:::db

    %% Agent Pipeline
    subgraph AGENTS ["🤖  Multi-Agent Pipeline  "]
        direction TB
        E["Agent 1 — Signal Triage\n─────────────────────\nLLM classifies event type\ntrend_break · volatility_spike\nmomentum_reversal · liquidity_stress"]:::agent

        F["Agent 2 — Risk Engine\n─────────────────────\n🛠️ Tool Calling\nRolling Vol · Max Drawdown\n1d/5d VaR · 1d/5d ES\nCorr Jump · Regime Score"]:::agent

        G["Agent 3 — Risk Memo\n─────────────────────\n📚 RAG Retrieval\nrisk_terms.csv\nhistorical_cases.csv\nagent_playbook.txt"]:::agent

        E --> F --> G
    end

    %% Market Data
    MD[(Yahoo Finance\nquantmod)]:::ext

    %% Knowledge Base
    KB[(Local Knowledge Base\nCSV + TXT)]:::ext

    %% Storage 2
    H[(SQLite\nanalyses table)]:::db

    %% Dashboard
    subgraph UI ["📊  Shiny Dashboard  "]
        direction LR
        P1["Page 1 — Executive Dashboard\nKPI Strip · TradingView Chart\nTriage Card · Risk Metrics\nMemo · Knowledge Panel"]:::ui
        P2["Page 2 — Alert Log & Ops\nAlert History Table\nJSON Traces · System Status"]:::ui
    end

    %% Connections
    A1 --> B
    A2 --> B
    B --> C
    C --> D
    C --> AGENTS
    MD -->|price history| F
    KB -->|retrieve context| G
    AGENTS --> H
    H --> UI
    D --> P2

    %% Styles
    classDef input    fill:#d7f0df,stroke:#125631,color:#125631,font-weight:bold
    classDef infra    fill:#e8f0fe,stroke:#3367d6,color:#1a3a6e
    classDef proc     fill:#fff3e0,stroke:#e65100,color:#6d2a00
    classDef agent    fill:#fce4ec,stroke:#c2185b,color:#7b003e,text-align:left
    classDef db       fill:#ede7f6,stroke:#512da8,color:#2d1462
    classDef ext      fill:#e0f2f1,stroke:#00695c,color:#003d35
    classDef ui       fill:#e3f2fd,stroke:#0d47a1,color:#08245c
```

## Component Summary

| Layer | Component | Technology |
|---|---|---|
| Input | Simulate Alert / TradingView Webhook | Shiny + Plumber |
| Ingestion | Payload normalization | R |
| Agent 1 | Signal Triage Agent | OpenAI GPT (LLM classification) |
| Agent 2 | Risk Engine Agent | Tool Calling → quantmod + custom R functions |
| Agent 3 | Risk Memo Agent | RAG → local CSV/TXT knowledge base |
| Storage | Alert + Analysis history | SQLite |
| Market Data | Price history | Yahoo Finance via quantmod |
| Frontend | Two-page dashboard | R Shiny + bslib + DT |
