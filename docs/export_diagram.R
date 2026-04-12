# Run this script to export the process diagram as a PNG for the .docx submission.
# Requires: DiagrammeR, DiagrammeRsvg, rsvg
# Install if needed:
#   install.packages(c("DiagrammeR", "DiagrammeRsvg", "rsvg"))

library(DiagrammeR)
library(DiagrammeRsvg)
library(rsvg)

diagram <- grViz("
digraph risk_dashboard {

  graph [rankdir=TB, fontname='Helvetica', bgcolor='#FAFAFA', pad=0.5, nodesep=0.5, ranksep=0.7]
  node  [fontname='Helvetica', fontsize=11, style=filled, shape=box, margin='0.18,0.12']
  edge  [fontname='Helvetica', fontsize=9, color='#607080']

  // ---------- Input ----------
  subgraph cluster_input {
    label='Input Sources'; style=dashed; color='#125631'; fontcolor='#125631'
    A1 [label='Simulate Alert\\n(Shiny Button)', fillcolor='#d7f0df', color='#125631', fontcolor='#125631']
    A2 [label='TradingView\\nWebhook POST', fillcolor='#d7f0df', color='#125631', fontcolor='#125631']
  }

  // ---------- Ingestion ----------
  B [label='Plumber Endpoint\\nwebhook.R', fillcolor='#e8f0fe', color='#3367d6', fontcolor='#1a3a6e']
  C [label='normalize_alert_payload()\\nSymbol · Event · Price · Timestamp', fillcolor='#fff3e0', color='#e65100', fontcolor='#6d2a00']
  D [label='SQLite\\nalerts table', shape=cylinder, fillcolor='#ede7f6', color='#512da8', fontcolor='#2d1462']

  // ---------- Agents ----------
  subgraph cluster_agents {
    label='Multi-Agent Pipeline'; style=filled; fillcolor='#fff8f8'; color='#c2185b'; fontcolor='#7b003e'
    E [label='Agent 1: Signal Triage\\n──────────────────\\nLLM classifies event type\\ntrend_break · volatility_spike\\nmomentum_reversal · liquidity_stress', fillcolor='#fce4ec', color='#c2185b', fontcolor='#7b003e']
    F [label='Agent 2: Risk Engine\\n──────────────────\\n[Tool Calling]\\nRolling Vol · Max Drawdown\\n1d/5d VaR & ES · Corr Jump · Regime Score', fillcolor='#fce4ec', color='#c2185b', fontcolor='#7b003e']
    G [label='Agent 3: Risk Memo\\n──────────────────\\n[RAG Retrieval]\\nrisk_terms · historical_cases · playbook', fillcolor='#fce4ec', color='#c2185b', fontcolor='#7b003e']
    E -> F -> G
  }

  // ---------- External ----------
  MD [label='Yahoo Finance\\n(quantmod)', shape=cylinder, fillcolor='#e0f2f1', color='#00695c', fontcolor='#003d35']
  KB [label='Local Knowledge Base\\nCSV + TXT files', shape=cylinder, fillcolor='#e0f2f1', color='#00695c', fontcolor='#003d35']
  H  [label='SQLite\\nanalyses table', shape=cylinder, fillcolor='#ede7f6', color='#512da8', fontcolor='#2d1462']

  // ---------- Dashboard ----------
  subgraph cluster_ui {
    label='Shiny Dashboard'; style=filled; fillcolor='#f0f6ff'; color='#0d47a1'; fontcolor='#08245c'
    P1 [label='Page 1: Executive Dashboard\\nKPI Strip · TradingView Chart\\nTriage · Risk Metrics · Memo · Knowledge', fillcolor='#e3f2fd', color='#0d47a1', fontcolor='#08245c']
    P2 [label='Page 2: Alert Log & Ops\\nAlert History · JSON Traces · System Status', fillcolor='#e3f2fd', color='#0d47a1', fontcolor='#08245c']
  }

  // ---------- Edges ----------
  A1 -> B
  A2 -> B
  B  -> C
  C  -> D
  C  -> E
  MD -> F [label='price history']
  KB -> G [label='retrieve context']
  G  -> H
  H  -> P1
  H  -> P2
  D  -> P2
}
")

# Export to PNG
svg_code <- export_svg(diagram)
rsvg_png(chartr("\n", " ", svg_code) |> chartr(" ", " ", x=_) |> (\(x) charToRaw(x))(),
         file = "docs/process_diagram.png",
         width = 1400, height = 900)

cat("Exported: docs/process_diagram.png\n")
