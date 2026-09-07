# Measurement history — what this project got wrong about itself

Moved out of `PROJECT.md` on 2026-09-05. That file is read at the start of every run, so it holds
what changes a decision **now**; this holds the record behind it.

One pattern runs through all of it: **every number this harness has reported about itself has been
wrong at least once, and a human refusing a figure that felt wrong found every one. No test did.**
That is the reason for the standing rule — check any self-reported figure against an independent
calculation before trusting it.

## The wrong numbers

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
| 4 (additive, 2026-09-05) | `host`: `claude-code` when absent from the payload, otherwise what the host adapter declares (`opencode`). Added the moment a second host could write to the same log, so `/iamlazy-review` never averages across hosts. Not a version bump: readers that ignore it lose nothing. |
| 5 | `drift_thresholds`, the breaker's settings in effect for that run; `abandoned` lines stop claiming to be schema 3 rather than the generation that wrote them |
| 6 | `drift_fired`, whether the breaker actually stopped that run — on flushed and abandoned lines alike |

Five and six landed the same day, one field each, which is one bump more than it should have taken:
logging the thresholds without logging whether they fired only looked complete until the breaker
fired for the first time and the log could not say so.

**Where the cost figure comes from depends on the host.** Claude Code exposes no per-message
cost, so the hooks derive it from the session transcript and `prices.conf`. OpenCode and Pi price
every assistant message themselves (`cost`, `tokens{input,output,reasoning,cache{read,write}}`
per message, verified in both stores on 2026-09-05), so their adapters hand the run's figure over in
a `<sid>.cost` sidecar — Critic included, baseline already subtracted — and the hooks use it as-is.
Deriving a second number from `prices.conf` on a host that already priced the run would produce two
figures that disagree, and this file is the record of why that is worse than one.

**A trailing `-YYYYMMDD` in a model id is a snapshot of the same model**, so it is stripped before
the price lookup. Found on 2026-09-06 while preparing the first Claude Code run of the dollar era:
`claude-haiku-4-5-20251001` appears 9,321 times in a week of real transcripts and `prices.conf`
lists `claude-haiku-4-5`, so the lookup missed and **every** Claude Code run would have logged
`cost_usd: null`. Nothing else is normalised: prefix-matching in general would price a
`claude-opus-6-preview` at opus-5 rates, and an unknown model is still reported by its full id so
the human can paste exactly what they saw.

**`human_interventions` is `null` where it cannot be derived.** It counts the interruption marker
in the session transcript, which only Claude Code keeps; OpenCode's adapter sends no transcript, so
the count is skipped. It logged `0` there until 2026-09-06 — a fifth wrong number, found by reading
the first real OpenCode run rather than by a test, and wrong in the same direction as the four
above: it asserted "the human never interrupted" where the honest value was "unknowable". Fixing it
also gave the field its first test, of either behaviour.

`/iamlazy-review` reports what each line actually has, never inferring across generations and never
converting between the two cost units. A line with no `base_ref` has **unmeasurable**
`files_changed` and `lines_changed` — not zero.

## What the real runs have and have not exercised

Two real `/iamlazy` runs landed on 2026-09-05 (`git-diff-viewer`). Between them they exercised the
contract, the gate, execution, review by the Critic, and the close — plus the sub-agent denial,
where the model **read the refusal and adapted in the same turn**, which is what confirms
`PreToolUse`'s `permissionDecisionReason` actually reaches it.

Three more landed on OpenCode on 2026-09-06, and the third is the one worth keeping: a run whose
contract, Critic, accounting and close all matched an independent recomputation to the digit; a run
where the plugin had failed to load, so Layer 1 was flawless and Layer 0 wrote nothing; and a run
where the scope gate **blocked a close for the first time on any host**. The model read the block
and reverted the stray file — and the run still could not close, because the turn that resolves a
block was being discarded. See `decisions-2026-09.md`.

Still unexercised, and the reason the "documented, not observed" entry stays in `PROJECT.md`:

- the scope gate blocking a close **on Claude Code** — it has now done so on OpenCode, where the
  adapter reads `decision: block` itself, which says nothing about whether Claude Code honours it
- ~~the circuit breaker under its current message shape~~ — fired in production for the first time
  on 2026-09-07 (OpenCode), with thresholds deliberately lowered through `~/.iamlazy/config` so the
  experiment cost $0.06 instead of the $3 a real trip needs. The model answered it correctly: "I am
  not going to invent a hypothesis or a failed attempt, because there are none." It was right — the
  run was healthy and the threshold was artificial, which is exactly what `PROJECT.md` says to
  conclude. The false positive cost 705s and $0.0565 against 331s and $0.0363 for the equivalent
  run without it
- `Stop`'s `{"decision":"block","reason":…}` reaching the model
- the gate **rejecting** a plan: across 29 logged runs, `gate_verdict` has never once been
  `rejected`
