# `data/eval/` — local evaluation artifacts

This directory is where `scripts/run_eval.R` writes the CSV artifacts for
the V2 single-pass vs V3 critic-loop comparison.

The canonical submitted summary is tracked in
[`docs/EVAL_RESULTS.md`](../../docs/EVAL_RESULTS.md). Slide 7 in
[`docs/SLIDES.md`](../../docs/SLIDES.md) and
[`docs/presentation.html`](../../docs/presentation.html) is filled from
that same summary.

The CSV outputs themselves are intentionally gitignored:

- `v2_memos.csv`
- `v3_memos.csv`
- `comparison.csv`
- `summary.csv`
- `manual_scores_template.csv`

They are generated locally and may contain model outputs tied to the
market data available at run time. Do not commit them. No API key should
ever be stored in this directory.

---

## How to generate the evidence

### Prerequisites

- Working `OPENAI_API_KEY` in your `.env`
- All R packages installed (see `README.md` § Quickstart)
- Yahoo Finance reachable from your network

### Run

```bash
cp .env.example .env
# edit .env, set OPENAI_API_KEY=<your-openai-api-key>

# Default: 1 alert per (asset × event_type) = 30 alerts.
# Each alert is run twice (V2-compat single-pass + V3 with critic loop).
# Total ~60 OpenAI calls, ~5 min, ~$0.05.
Rscript scripts/run_eval.R 1
```

For a beefier sample (same demo cost trade-off):

```bash
# 2 alerts per (asset × event_type) = 60 alerts, ~10 min, ~$0.10
Rscript scripts/run_eval.R 2
```

### Output files

After the run, this directory will contain:

| File | What's in it |
|---|---|
| `v2_memos.csv` | One row per alert, V2-compat single-pass output: headline, memo, action, Critic auto-scores |
| `v3_memos.csv` | Same alerts, V3 with critic loop: includes `iterations_used` |
| `comparison.csv` | Joined V2/V3 with deltas per dimension |
| `summary.csv` | One-row summary: means, pass rates, latency, % needing iter 2 |
| `manual_scores_template.csv` | Both V2 and V3 memos, with columns for 3 reviewers to fill in 1-10 scores |

---

## Manual scoring (3 reviewers × N memos)

After the run, fill in `manual_scores_template.csv` (one row per
memo per version, 1-10 scale). Each team member should score independently
without seeing each other's scores. Average the three reviewer columns
per row, then average across rows for V2 vs V3.

The template has these columns:

```
label,eval_id,symbol,event_type,headline,memo,action,
reviewer_1_score,reviewer_2_score,reviewer_3_score,notes
```

Save it as `manual_scores.csv` (without `_template`) when complete.

---

## Keeping the deck in sync

If you re-run the eval, update these files together:

- `docs/EVAL_RESULTS.md`
- `docs/SLIDES.md` Slide 7
- `docs/presentation.html` Slide 7

Do not show invented or stale numbers. If you do not re-run the eval,
use the current tracked summary in `docs/EVAL_RESULTS.md`.

---

## Don't commit the CSVs

The eval CSVs contain LLM outputs that include the Yahoo Finance market
state at the moment they were generated. Committing them inflates repo
size and creates pseudo-determinism that masks future prompt drift.

`.gitignore` already excludes `data/eval/*.csv`. Keep it that way.

If a TA asks for the artifacts, send them as a zip via Canvas or email.
