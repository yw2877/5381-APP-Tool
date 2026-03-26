# TradingView Multi-Agent Risk Dashboard

## 1. Project Overview

### Project Name
TradingView Multi-Agent Risk Dashboard

### Project Positioning
This project is a dashboard-first market risk application for traders, risk analysts, and course-demo stakeholders. TradingView is used as the charting and alert-trigger layer, while the Shiny backend is responsible for risk computation, agent orchestration, retrieval, logging, and memo generation.

### Core Value Proposition
The app is designed to answer one practical question:

> When a market alert is triggered, is this noise, or an early signal of risk escalation?

### Why This Scope Is Strong
- It clearly demonstrates multi-agent orchestration.
- It naturally supports tool calling through risk metrics functions.
- It naturally supports RAG through local knowledge retrieval.
- It is more defensible academically than a simple “predict tomorrow’s price” app.
- It is easier to implement than a full TradingView datafeed integration.

## 2. Product Goal

The final product should provide:

- A professional risk dashboard layout
- TradingView chart visualization
- TradingView alert ingestion through webhook
- Three coordinated agents with distinct responsibilities
- Risk metrics computed from backend tools
- A small but well-structured local RAG knowledge base
- A persistent alert and analysis log
- A clear end-to-end demo path for presentation

## 3. Final Product Shape

The recommended final product is a two-page dashboard app.

### Page 1: Executive Risk Dashboard
This is the primary demo page. It should show the full business story in one view.

Sections:
- Top KPI strip
- TradingView chart panel
- Current alert summary panel
- Agent analysis panel
- Risk metrics dashboard panel
- Knowledge and similar cases panel

### Page 2: Alert Log and Operations
This is the supporting detail page for technical review and operations visibility.

Sections:
- Alert history table
- Raw webhook payload viewer
- Agent JSON trace
- Knowledge base viewer
- Simulated alert panel
- System health and status panel

## 4. Dashboard Layout Recommendation

### Page 1 Layout

#### Top Row
- App title
- Asset selector
- Time window selector
- Simulate alert button
- Refresh button
- Current risk badge
- Latest alert timestamp

#### Main Left
- Embedded TradingView chart widget or iframe
- Asset identity label
- Active signal type tag

#### Main Right
- Current alert summary card
- Signal Triage Agent card
- Risk Memo Agent card

#### Bottom Section
- Risk metrics grid
- Similar historical cases
- Risk term definitions
- Recommended watch items

### Page 2 Layout

#### Top Section
- Alert history table
- Filter by asset
- Filter by alert type
- Filter by date/time

#### Lower Section
- Raw webhook payload viewer
- Triage JSON
- Metrics JSON
- Memo output
- System status indicators

## 5. System Architecture

The app should follow this fixed pipeline:

1. TradingView chart is embedded in the dashboard.
2. TradingView alert fires from Pine Script or chart conditions.
3. TradingView sends an HTTP POST webhook to a plumber endpoint.
4. The backend normalizes the incoming payload.
5. Signal Triage Agent classifies the event.
6. Risk Engine Agent calls local risk tools.
7. RAG retrieves relevant risk definitions and historical cases.
8. Risk Memo Agent writes a concise stakeholder-facing summary.
9. Results are stored in SQLite.
10. Shiny dashboard displays the latest analysis and history.

## 6. Functional Modules

### Module A: Dashboard UI
Responsibilities:
- Executive dashboard page
- Alert log and operations page
- KPI cards
- Tables
- Panel layout
- Visual design and responsiveness

### Module B: TradingView Integration
Responsibilities:
- TradingView iframe/widget embedding
- Alert setup and webhook target configuration
- Alert JSON formatting
- Symbol switching behavior

### Module C: Webhook and Persistence
Responsibilities:
- Plumber endpoint
- Webhook secret validation
- Payload normalization
- SQLite storage
- Alert history persistence

### Module D: Risk Engine
Responsibilities:
- Market price retrieval
- Return series generation
- Rolling volatility
- Max drawdown
- Historical VaR
- Expected Shortfall
- Correlation jump
- Regime score

### Module E: Agent Layer
Responsibilities:
- Agent 1 signal classification
- Agent 2 metric generation and interpretation
- Agent 3 memo generation
- Standardized output schema

### Module F: RAG Layer
Responsibilities:
- Risk term definitions
- Historical similar cases
- Agent playbook guidance
- Retrieval and packaging for the memo agent

## 7. Agent Definitions

### Agent 1: Signal Triage Agent
Purpose:
Classify the incoming alert into a market event category.

Inputs:
- Alert type
- Alert text
- Symbol
- Trigger price
- Time

Outputs:
- Signal type
- Severity hint
- Why this event matters
- What should be checked next

Example categories:
- trend_break
- volatility_spike
- momentum_reversal
- liquidity_stress
- watchlist_signal

### Agent 2: Risk Engine Agent
Purpose:
Run risk tools and identify what is currently driving risk.

Inputs:
- Symbol
- Lookback window
- Market data
- Triage result

Outputs:
- Rolling volatility
- Max drawdown
- 1-day VaR
- 5-day VaR
- 1-day ES
- 5-day ES
- Correlation jump
- Regime score
- Primary driver
- Current risk level

### Agent 3: Risk Memo Agent
Purpose:
Transform the event and metric outputs into a concise stakeholder memo.

Inputs:
- Alert data
- Triage output
- Risk metrics
- Retrieved knowledge

Outputs:
- Headline
- Executive memo
- Recommended next action

## 8. Data and Storage Design

### Market Universe
Recommended first-release assets:
- BTCUSDT
- ETHUSDT
- SPY
- QQQ
- NVDA

### Storage
Use SQLite for the first version.

Recommended tables:
- `alerts`
- `analyses`
- optional `price_cache`

### Local Knowledge Base
Recommended files:
- `risk_terms.csv`
- `historical_cases.csv`
- `agent_playbook.txt`

## 9. Scope Definition

### P0 Must-Have Scope
- 5 assets or fewer
- TradingView chart embed
- Webhook endpoint
- Three-agent pipeline
- Risk metrics panel
- Alert history panel
- Local RAG support
- Simulate alert function
- Shiny deployment target

### P1 Stretch Scope
- User upload of a small holdings file
- Portfolio-level rollup risk view
- Better market data adapter
- Export memo feature
- Cloud deployment hardening

### Out of Scope for First Version
- Full portfolio optimization
- Automated trading execution
- High-frequency live streaming architecture
- Large-scale vector database setup
- Complex prediction modeling

## 10. Detailed Action Plan

### Phase 1: Specification Freeze
Goal:
Lock the final app shape before heavy coding.

Tasks:
- Finalize the two-page dashboard structure
- Finalize the monitored asset list
- Finalize the alert payload schema
- Finalize the output schema for triage, risk, and memo
- Finalize the list of metrics shown on Page 1
- Finalize file ownership across team members

Deliverables:
- UI wireframe
- JSON schema draft
- team ownership matrix

### Phase 2: Dashboard Skeleton
Goal:
Build the visual shell of the app with placeholders.

Tasks:
- Build Page 1 dashboard layout
- Build Page 2 operations layout
- Add placeholder KPI cards
- Add placeholder chart region
- Add placeholder metrics cards
- Add placeholder history table
- Add placeholder memo panel

Deliverables:
- clickable dashboard shell
- stable UI layout for integration

### Phase 3: Webhook Pipeline
Goal:
Make alerts enter the system reliably.

Tasks:
- Create plumber endpoint
- Validate POST request handling
- Define secret header behavior
- Normalize TradingView payload
- Save alerts to SQLite
- Add health-check endpoint
- Add local curl test path

Deliverables:
- working webhook service
- stored alerts in database

### Phase 4: Risk Tools Integration
Goal:
Make the backend produce quantitative risk outputs.

Tasks:
- implement price history adapter
- implement return generation
- implement rolling volatility
- implement max drawdown
- implement historical VaR and ES
- implement correlation jump
- implement regime score
- expose metric outputs to dashboard

Deliverables:
- working risk metrics pipeline
- metrics visible in UI

### Phase 5: Agent Integration
Goal:
Convert raw alerts into structured interpretations.

Tasks:
- implement Signal Triage Agent flow
- implement Risk Engine Agent flow
- implement Memo Agent flow
- standardize agent outputs
- render agent results in dashboard cards

Deliverables:
- consistent triage output
- consistent memo output

### Phase 6: RAG Integration
Goal:
Add contextual explanation and academic value.

Tasks:
- prepare risk terms file
- prepare historical cases file
- prepare playbook notes
- implement retrieval logic
- render retrieved content in dashboard
- feed retrieved context into memo generation

Deliverables:
- knowledge cards in dashboard
- explainable memo content

### Phase 7: TradingView Live Integration
Goal:
Replace placeholders with the real chart and real alerts.

Tasks:
- embed TradingView widget
- align UI asset selector with widget symbols
- configure TradingView alerts
- point alerts to webhook URL
- validate real alert payloads
- compare real payload behavior to simulated alerts

Deliverables:
- live TradingView chart
- real webhook-driven app behavior

### Phase 8: Deployment and Demo Polish
Goal:
Make the app presentation-ready.

Tasks:
- deploy Shiny app
- deploy webhook service
- verify environment variables
- prepare demo script
- prepare screenshots and architecture diagram
- prepare final README
- prepare class presentation flow

Deliverables:
- deployed app
- reliable demo process

## 11. Weekly Team Timeline

### Week 1
- Freeze requirements
- Agree on layout
- Agree on JSON schemas
- Build UI skeleton
- Build SQLite structure
- Build simulate alert path

### Week 2
- Implement webhook pipeline
- Implement risk metrics functions
- Connect dashboard to stored results
- Start agent outputs

### Week 3
- Integrate RAG
- Integrate TradingView live alerts
- Polish UI
- Test full demo flow
- finalize deployment and presentation

## 12. Four-Person Team Split

### Member 1: Dashboard and Frontend Lead
Responsibilities:
- Own Shiny layout and page design
- Build Page 1 executive dashboard
- Build Page 2 operations page
- Build KPI cards, tables, and layout logic
- Own visual polish and responsive behavior

Primary Deliverables:
- stable front-end structure
- dashboard-ready visuals
- embedded chart display region

Suggested File Ownership:
- UI files
- styling files
- dashboard output rendering

### Member 2: TradingView and Webhook Lead
Responsibilities:
- Own TradingView integration
- Configure alerts in TradingView
- Implement and test plumber webhook
- Define payload schema
- Handle alert ingestion and validation
- Test local and deployed webhook flow

Primary Deliverables:
- working TradingView alert pipeline
- verified webhook endpoint
- stored incoming alerts

Suggested File Ownership:
- webhook service
- alert normalization
- alert ingestion and storage interface

### Member 3: Risk Engine and Quant Lead
Responsibilities:
- Own market data handling
- Own return series logic
- Implement all risk metrics
- Define thresholds and risk scoring logic
- Ensure metric consistency and correctness

Primary Deliverables:
- working risk tool layer
- metric outputs for dashboard and agents

Suggested File Ownership:
- market data files
- risk functions
- numeric backend utilities

### Member 4: Agents, RAG, and Deployment Lead
Responsibilities:
- Own the three-agent orchestration design
- Define agent prompts and output schemas
- Own local RAG files and retrieval
- Generate executive memo behavior
- Own deployment setup and final demo flow
- Help produce README and presentation materials

Primary Deliverables:
- working agent pipeline
- knowledge retrieval
- deployment-ready flow

Suggested File Ownership:
- agent orchestration files
- RAG files
- deployment and documentation

## 13. Collaboration Rules

- Do not let all four people edit the same core files at once.
- Freeze schemas early.
- Use one integration branch or integrate daily to reduce merge conflicts.
- Keep a single shared analysis object structure across the app.
- Maintain a shared list of required environment variables.
- Do not delay demo readiness waiting for live TradingView integration.
- Always preserve the simulated alert path as a fallback.

## 14. Suggested Git Workflow

- `main`: stable demo-ready branch
- feature branches per owner:
  - `feature/dashboard-ui`
  - `feature/tradingview-webhook`
  - `feature/risk-engine`
  - `feature/agents-rag`

Rules:
- open pull requests into `main`
- avoid direct commits to `main` during heavy development
- merge only after local smoke test

## 15. Demo Script Recommendation

The presentation should follow a clear sequence:

1. Open the executive dashboard.
2. Select one asset such as BTCUSDT.
3. Show the TradingView chart.
4. Trigger a simulated or real alert.
5. Show the alert entering the system.
6. Show Agent 1 classification.
7. Show Agent 2 risk metrics.
8. Show Agent 3 memo.
9. Show similar cases and retrieved risk definitions.
10. Open the log page and show raw payload plus system trace.

## 16. Risk Register

### Risk 1: TradingView webhook is unstable during demo
Mitigation:
- keep simulate alert functionality

### Risk 2: market data source is not ready
Mitigation:
- keep mock or cached prices as fallback

### Risk 3: agent outputs are inconsistent
Mitigation:
- force standardized structured outputs

### Risk 4: deployment blocks webhook connectivity
Mitigation:
- test local first with tunnel
- keep a local backup demo path

### Risk 5: team merge conflicts slow progress
Mitigation:
- assign file ownership
- integrate frequently

## 17. Final Success Criteria

The project is ready when the following are true:

- Users can select an asset
- Users can view a TradingView chart
- An alert can be triggered by simulation or live webhook
- The alert is persisted
- Three agent outputs are visible
- Risk metrics are displayed clearly
- RAG content is displayed and relevant
- The app looks like a professional dashboard
- The full end-to-end story can be demonstrated in under five minutes

## 18. Immediate Next Actions

### Team-Level Next Actions
- Confirm final dashboard layout
- Confirm asset universe
- Confirm page structure
- Confirm file ownership by member
- Confirm risk metrics list

### Build-Level Next Actions
- keep the current scaffold as the base architecture
- upgrade the visual structure toward a full dashboard layout
- wire TradingView into the chart panel
- finalize the webhook payload shape
- connect real market data when available

---

This plan is intended to function as the execution reference for design, implementation, collaboration, and final presentation.
