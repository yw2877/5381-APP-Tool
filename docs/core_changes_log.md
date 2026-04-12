# Core Changes Log

Date: 2026-04-12

## 1. Alert Outputs Are Now Integrated Into The Main App Flow

- The homepage agent panel now reads the latest stored alert analysis from the database instead of rebuilding a temporary `baseline_check` every time.
- This means alerts created by `Simulate` or incoming webhook payloads now drive the actual Triage and Memo content shown in the app.
- The `Last Alert` KPI now reflects the real latest alert timestamp from storage rather than behaving like a proxy for the current page refresh time.
- Simulated alerts trigger an immediate UI refresh after storage, so the dashboard updates right away.

Relevant files:
- `R/server.R`
- `R/pipeline.R`

## 2. Alert Data Model Was Expanded And Persisted

- The alert schema now stores `reference_type` and `reference_level` so alerts can explain what benchmark or threshold was used.
- The analysis schema now stores `recommended_action` so memo outputs are preserved and can be shown again later.
- Existing SQLite tables are migrated automatically if those columns are missing.
- Recent alert tables and operations views now surface the new reference fields directly in the UI.

Relevant files:
- `R/storage.R`
- `R/agents.R`
- `R/server.R`

## 3. Simulated Signals Are More Meaningful

- Users can now choose the simulated event type instead of always relying on a random alert type.
- New event options include `support_break` and `resistance_break`.
- Simulated alerts now generate more realistic `trigger_price`, `reference_type`, and `reference_level` values based on the selected event logic, rather than always reusing the latest price.
- This makes the alert feed and agent explanation closer to real market-signal behavior.

Relevant files:
- `R/ui.R`
- `R/config.R`
- `R/pipeline.R`

## 4. Triage And Memo Panels Show Clearer Alert Context

- The Triage panel now includes a compact summary of the selected alert:
  - `Event Type`
  - `Signal Type`
  - `Trigger Price`
  - `Reference`
  - `Severity`
  - `Received`
- The Memo panel and operations detail view now expose the stored `recommended_action` when available.

Relevant files:
- `R/server.R`
- `www/styles.css`

## 5. Knowledge Sections Were Reorganized

- `Risk Overview` now focuses on `Risk Terms` and `Playbook` only.
- `Historical Cases` was removed from the overview page to avoid repeating the same content across pages.
- `Alert Log & Ops` keeps the historical case section, which now behaves like an asset-first case viewer:
  - if no alert is selected, it shows 4 general cases;
  - if an asset is selected, that asset's cases are pushed to the front;
  - the panel always shows 4 cards without extra explanatory text.

Relevant files:
- `R/ui.R`
- `R/server.R`
- `R/knowledge.R`
- `data/knowledge/historical_cases.csv`

## 6. Historical Case Library Was Refreshed

- The historical case dataset was updated with newer, product-ready cases tied to the assets used in the dashboard.
- The case library now includes structured metadata such as:
  - `case_date`
  - `asset_focus`
  - `market_regime`
- This supports cleaner display and better matching behavior in the operations page.

Relevant files:
- `data/knowledge/historical_cases.csv`
- `R/knowledge.R`

## 7. Dashboard Layout And Control Bar Were Tightened

- The main dashboard layout was rebalanced so charts and agent panels align more cleanly.
- The top control row was adjusted so `Asset`, `Lookback`, `Event`, `Alert`, `Refresh`, and `Current Risk` have consistent sizing and stay inside the hero card.
- Long asset labels such as `BTCUSDT` are handled more cleanly in the control area.
- The `Current Risk` badge now uses a more consistent width and centered alignment.
- `Risk Terms` no longer uses an unnecessary inner scroll container.

Relevant files:
- `R/ui.R`
- `www/styles.css`

## Final Outcome

The app now better demonstrates three core project goals:

- agent outputs are directly integrated into visible app functionality;
- alerts carry clearer market context through stored reference fields;
- the UI is more coherent, easier to read, and better aligned with the assignment requirements.
