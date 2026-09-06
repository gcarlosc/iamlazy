# Measurement history — what this project got wrong about itself

Moved out of `PROJECT.md` on 2026-09-05. That file is read at the start of every run, so it holds
what changes a decision **now**; this holds the record behind it.

One pattern runs through all of it: **every number this harness has reported about itself has been
wrong at least once, and a human refusing a figure that felt wrong found all four. No test did.**
That is the reason for the standing rule — check any self-reported figure against an independent
calculation before trusting it.

## The four wrong numbers

| Field | How wrong | How it was found | Outcome |
|---|---|---|---|
| `tokens_total` | wrong in 7 of 7 runs, up to ~94x | human disbelief, 2026-08-19 | removed; it needed an external observer the no-runtime design forbade |
| `tokens_weighted` | ~2.1x high (measured: 1,176,836 reported vs 561,234 actual) | human disbelief, 2026-08-27 | a transcript records the same assistant message once per streaming chunk; deduplicated by message id |
| `tokens_weighted`, again | not numerically wrong — the wrong **unit** | human disbelief, 2026-09-05 | see below |
| `files_changed` / `lines_changed` | 0 on real work | a run's commit of 1,774 lines logged as 0 | `git diff` with no ref shows only *unstaged* work; now diffed against `base_ref` |

The second `tokens_weighted` failure is the subtlest and worth keeping in full. The figure was
arithmetically exact — an independent recomputation matched the logged value to the digit — and
still misleading twice over:

- **Blind to the model.** It normalised everything to input-token-equivalents, so a Sonnet token
  and an Opus token counted the same while costing 2.5x apart. One measured run was 86%
  Sonnet-weighted: priced entirely at Opus rates the same figure reads $6.07, at Sonnet rates
  $2.43, and the truth was $3.02. Ranking cost across runs was the field's only job.
- **Excluded the Critic**, which runs in its own transcript: $0.50 of a $3.53 run.

And the complaint that surfaced it — "1.21M for a simple task, that's exaggerating" — was itself
wrong in an instructive way. That run really moved ~6M tokens, 93% of them cache reads across 77
turns. The weighted figure was the *deflated* number; every reader took it for the inflated one.
The lesson is not "the number was too big" but **"the unit was unreadable, so nobody could tell"**.

## Circuit breaker calibration

Recalibrated 2026-09-05 in dollars, from four measured run deltas (Critic included, post-close
activity excluded):

| Lines changed | Cost | $ / line |
|---|---|---|
| 27 | $1.75 | 0.0647 |
| 48 | $1.45 | 0.0301 |
| 66 | $2.60 | 0.0393 |
| 156 | $3.53 | 0.0226 |

**Cost per line falls as a run grows.** Reading, planning, contracting and reviewing cost the same
whatever the diff is, so a small task is dear per line without being sick — which is why the floors
carry more weight than the ratio, and why the rule is really "expensive AND unproductive" rather
than "unproductive". The threshold sits at $0.08/line, 2x the worst healthy run above the 50-line
floor. The lost run (4.75M weighted over 230 lines, Opus-priced ~$23.75) computes to $0.103 and
still fires.

The previous calibration is worth remembering as a cautionary tale: it used a token sum that
double-counted usage blocks, so the healthy baseline *and* the threshold were inflated by the same
error and the ratio looked sane. A ratio between two numbers that are wrong the same way looks
right.

## `runs.jsonl` schema generations

| Version | What it added |
|---|---|
| 1 (pre-Layer 0) | self-reported: `reversibility`, `critic_mode`, `gate_verdict`, `outcome: success` |
| 2 | derived by hooks: `task_summary`, `duration_seconds`, `files_changed`, `lines_changed`, `tokens_weighted`, `project_md`, `close_detected_via` |
| 3 | `base_ref`, `stage_reached`, `critic_findings`, `outcome: abandoned`, `human_interventions` as a per-run delta |
| 4 | `cost_usd` + `cost_unpriced` + raw `tokens_output` / `tokens_cache_write` / `tokens_cache_read`, replacing `tokens_weighted` |

`/iamlazy-review` reports what each line actually has, never inferring across generations and never
converting between the two cost units. A line with no `base_ref` has **unmeasurable**
`files_changed` and `lines_changed` — not zero.

## What the real runs have and have not exercised

Two real `/iamlazy` runs landed on 2026-09-05 (`git-diff-viewer`). Between them they exercised the
contract, the gate, execution, review by the Critic, and the close — plus the sub-agent denial,
where the model **read the refusal and adapted in the same turn**, which is what confirms
`PreToolUse`'s `permissionDecisionReason` actually reaches it.

Still unexercised, and the reason the "documented, not observed" entry stays in `PROJECT.md`:

- the scope gate **blocking** a close (no run has deviated yet)
- the circuit breaker under its current message shape — it fired once on 2026-08-26, but under the
  old `hookSpecificOutput.systemMessage` form, on a run that never closed
- `Stop`'s `{"decision":"block","reason":…}` reaching the model
- the gate **rejecting** a plan: across 29 logged runs, `gate_verdict` has never once been
  `rejected`
