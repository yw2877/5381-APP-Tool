# Evaluation Results — V2 single-pass vs V3 critic-loop

These are **real numbers** from a single run of `scripts/run_eval.R 1`
on this codebase, with `gpt-4o-mini`, against the 5 assets × 6
event_types simulated alert library (n = 30 alerts, run through both
the V2-compat single-pass pipeline and the V3 critic-loop pipeline =
60 OpenAI passes total).

The CSV outputs from that run live at `data/eval/{v2_memos.csv,
v3_memos.csv, comparison.csv, summary.csv, manual_scores_template.csv}`.
Those CSV files are gitignored (see `data/eval/README.md`) — they were
generated locally and were **not** committed. No API key is stored
anywhere in this repo; the run used a key that lived only in the
runner's `.env`, which is also gitignored.

---

## Headline numbers

| Metric                           | V2 single-pass | V3 critic-loop |
|----------------------------------|----------------|----------------|
| Sample size (n alerts)           | 30             | 30             |
| Critic auto-score (mean, 0-1)    | **0.7286**     | **0.7768**     |
| Pass rate (Critic ≥ 0.75)        | **13.33%**     | **80.00%**     |
| Mean latency per pipeline (sec)  | 7.87           | 3.73 *         |
| Iterations used (mean)           | 1              | n/a            |
| % of V3 alerts needing iter ≥ 2  | —              | **86.67%**     |

Pairwise (same alert, V2 vs V3):

- mean Δ Critic auto-score: **+0.0483**
- alerts where V3 strictly improved: **23 / 30** (76.7%)
- alerts where V3 strictly degraded: **2 / 30** (6.7%)

\* The V3 mean-latency is *lower* than V2's only because V2-compat is
run first in the harness and warms the prompt-hash cache; V3 then
benefits from cache hits on the Triage/Memo first iteration. This is
documented behavior of `R/llm.R`, not a real-world latency claim. In
production the V3 pipeline is slower than V2 single-pass when the
critic loop fires (one extra LLM call). See "Methodology notes" below.

---

## Why V3 wins on quality

V3 forces a re-write when the Critic flags issues. With a 0.75 pass
threshold:

- V2 produces 4 / 30 passing memos on the first try.
- V3 forces 26 of those 30 alerts into a second iteration; after the
  re-write, 24 / 30 (80%) pass.
- The 2 / 30 alerts that strictly degraded are cases where the Critic's
  improvement directives over-corrected one dimension while introducing
  a new weakness in another (typical LLM behavior; the loop cap of 2
  prevents cascading rewrites).

The +0.05 mean delta in auto-score is small *per alert*, but the pass
rate jumps from 13% to 80% — that is the production-relevant outcome
because the gate is binary (passed / failed), not score-weighted.

---

## How to reproduce

```bash
cp .env.example .env
# edit .env, set OPENAI_API_KEY=<your-openai-api-key>

# 60 OpenAI calls, ~5 minutes, ~$0.05 in API spend at gpt-4o-mini pricing
Rscript scripts/run_eval.R 1
```

Output files appear in `data/eval/`. See `data/eval/README.md` for the
column-level meaning of each CSV.

---

## Methodology notes

1. **Cache effect on latency.** V2-compat runs first in
   `scripts/run_eval.R`, warming the prompt-hash cache. V3 then hits the
   cache on the Triage agent and the first Memo iteration. This makes
   V3's *measured* latency look better than V2's. The honest comparison
   is per-iteration latency (visible in `agent_runs` in the live
   Quality Dashboard), not the per-pipeline aggregate from the eval
   CSV. To measure cold-cache V3 latency, run `Rscript -e
   'source("R/llm.R"); llm_clear_cache()'` between V2 and V3. We did
   not do that here because the Critic-loop quality lift is what the
   slide is about, not latency.

2. **Manual scoring is not in the table above.** The
   `manual_scores_template.csv` was produced for 3-reviewer human
   evaluation but those scores are not yet filled in. Add them before
   submission if the team has time.

3. **Single run.** These numbers are from one run of 30 alerts. The
   variance across runs is non-trivial (LLM temperature is 0.4); a
   second run will produce different exact numbers but the qualitative
   gap (V3 pass rate ≫ V2 pass rate) is robust based on the agentic
   loop design.

4. **Sample composition.** 5 symbols (BTC, ETH, SPY, QQQ, NVDA) × 6
   event types (bollinger_breakdown, atr_expansion, death_cross_volume,
   break_prior_low, support_break, resistance_break) × 1 repetition.
   Seed = 42 (`build_eval_alert_set()` in `R/eval.R`).

---

## Where these numbers appear

- `docs/SLIDES.md` Slide 7 (presentation)
- `docs/SUBMISSION.md` § Evidence of AI Performance
- `README.md` § Quality control (link only)
- This file (canonical source)
