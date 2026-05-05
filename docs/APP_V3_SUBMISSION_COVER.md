# Market Stress Copilot - App V3 Submission

## Links

**GitHub Repository:**  
https://github.com/yw2877/5381-APP-Tool

**Live App:**  
https://stingray-app-l8znn.ondigitalocean.app/

**Presentation / Demo Script:**  
https://github.com/yw2877/5381-APP-Tool/blob/main/docs/APP_V3_DEMO_SCRIPT.md

## Project Summary

Market Stress Copilot is our App V3 version of the deployed Shiny application. It is a market-risk dashboard that turns a market alert into a short risk briefing using a multi-agent AI workflow.

The app supports equities and crypto assets, computes risk metrics from real market data, generates a concise memo, and then uses a Critic Agent to check the quality of that memo. If the memo does not meet the quality threshold, the system can send feedback back to the Memo Agent for another iteration.

The biggest App V3 changes are the redesigned UI, the agent pipeline trace, the Critic Agent quality gate, the Quality Dashboard, the Alert Log & Ops page, and the DigitalOcean deployment.

## What We Submitted

We are submitting the GitHub repository, the live DigitalOcean app, and the demo script with screenshots. The live app is the main artifact. The demo script is there to support the in-class walkthrough and to show the same flow if the live app is slow during presentation.

Most of the production-ready work is visible directly in the deployed app: the cleaner dashboard layout, asset pages, cross-asset risk overview, quality dashboard, alert log, system status, and agent telemetry.

The quality-control work is mainly shown through the Critic Agent, the Critic Dimensions panel, the Quality Dashboard, and the evaluation results in `docs/EVAL_RESULTS.md`. In the tracked evaluation, the V2 single-pass pipeline had a Critic pass rate of **13.33%**, while the V3 critic-loop pipeline improved to **80.00%**.

## Where to Find Each Requirement

| Requirement | Where to Look |
|---|---|
| Production-ready functional app | Open the live app. The main evidence is the redesigned dashboard, equities/crypto pages, Risk Overview, Quality Dashboard, Alert Log & Ops page, and System Status panel. |
| Stakeholder alignment | Live app and demo script. Traders use the memo/action view, risk officers use the Risk Overview and historical cases, and technical users use the telemetry and Alert Log & Ops views. |
| Clarity | Live app. The sidebar navigation, KPI cards, asset dropdowns, tooltips, agent tabs, and dashboard sections are meant to make the workflow easy to follow. |
| Streamlining | Live app. The app is organized around a few focused pages: asset dashboards, cross-asset overview, quality monitoring, and alert operations. |
| Efficiency | GitHub repo and live app. App V3 adds caching, lazy chart loading, async webhook handling, and hidden-output suspension so the app feels more responsive. |
| Reliability | GitHub repo and Alert Log & Ops page. The app includes health/status checks, error handling, degraded fallback behavior, SQLite storage, Docker deployment files, and agent telemetry. |
| Quality control implementation | Quality Dashboard, Critic Dimensions panel, Agent Pipeline Trace, and code in `R/llm.R`, `R/schemas.R`, and `R/quality.R`. |
| Evidence of AI performance | Quality Dashboard and `docs/EVAL_RESULTS.md`. The V2 pass rate was 13.33%, while the V3 critic-loop pass rate improved to 80.00%. |
| Presentation materials | Demo script with screenshots: https://github.com/yw2877/5381-APP-Tool/blob/main/docs/APP_V3_DEMO_SCRIPT.md |
| Deployed app link | Live app: https://stingray-app-l8znn.ondigitalocean.app/ |

## Notes

The live app is the best place to see the final product. The Quality Dashboard and Alert Log & Ops page are the clearest places to see the App V3 validation, transparency, and production-readiness work.
