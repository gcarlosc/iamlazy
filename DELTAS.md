# DELTAS.md — evidence-gated backlog

Ideas evaluated and deliberately **not** adopted, each behind a trigger observable in
`~/.iamlazy/runs.jsonl` or session history. An entry without a concrete trigger does not
enter this file. A fired trigger prompts evaluation of the candidate — never auto-adoption.
When a candidate is adopted or discarded for good, record the outcome here and prune it.

## Candidate 1 — Brief quality checklist (origin: spec-kit `/speckit.checklist`)

Idea: validate the QUALITY of A1 — completeness, clarity, buried ambiguities — not just its
shape. "Unit tests for the natural-language requirement."
Trigger: 2+ runs where an ambiguous requirement left unquestioned in A1 caused rework after
the gate.
Status: 0 occurrences recorded.

## Candidate 2 — Coverage-driven questioning in A1 (origin: spec-kit `/speckit.clarify`)

Idea: A1's questions sweep defined dimensions (actors, boundary states, error handling,
data, integrations, non-functionals) instead of free generation. Rescue the coverage
taxonomy only — spec-kit's one-question-at-a-time interactive loop contradicts A1's
single-block rule and is not a candidate.
Trigger: same as Candidate 1 — if it fires, evaluate both as a single change to A1's shape.
Status: 0 occurrences recorded.

## Candidate 3 — Scannable list cap (origin: i-have-adhd rule 9)

Idea: cap human-visible lists (A1 question block, A3 steps) at ~5 scannable items, splitting
longer ones into "do now" vs "later". iamlazy already caps by LINES (A1 ≤15, A3 ≤30) but not
by item count — a block can pass the line cap and still overwhelm a scanning reader.
Trigger: 2+ runs where an A1/A3 block with >5 items caused reader confusion or rework.
Status: 0 occurrences recorded.

## Candidate 4 — `## Expected scope` block in A3 (origin: metrics-instrumentation session, Step 2)

Idea: A3 declares the file paths / scope boundaries it expects to touch, so A4 can be checked
against it and drift becomes observable. Deliberately deferred from Step 1 (per-run metrics,
this change) — adding it now would change agent behavior and contaminate the measurement
baseline before it's collected.
Trigger: not a hypothesis — scheduled. 5 baseline runs recorded in `runs.jsonl` after Step 1
lands.
Status: checkpoint met (2026-08-19) — 7 real runs recorded post-Step-1, exceeding the 5-run
baseline. Evaluated, not auto-adopted: `files_changed`/`lines_changed` (computed via
`git diff --stat`, not self-reported — trustworthy) show 6/7 runs at 760–2034 changed lines,
past the 400-line floor. That's evidence real tasks routinely don't fit one Plan, which is what
motivated **decomposition into per-step delivery** (see PROJECT.md 2026-08-19, revised 08-22) — not this block
directly. Once large work decomposes into per-step delivery, each step's own diff is the unit "scope"
should be checked against; evaluating a scope-drift mechanism before that existed would have
measured the wrong thing. Re-evaluate after a few decomposed runs land.

## Candidate 5 — Scope drift comparator (origin: metrics-instrumentation session, Step 3)

Idea: compare A3's declared scope (Candidate 4) against A4's actual diff paths; report drift.
Trigger: written in observable terms only in the second measurement window, after Candidate 4
lands — the Step 1 baseline cannot measure scope drift (no declared scope exists yet).
Status: blocked on Candidate 4, which is itself now deferred behind per-step delivery
(2026-08-19, revised 08-22) — see Candidate 4.

## Candidate 6 — Dynamic reversibility recalculation from the real diff

Idea: instead of relying only on the agent's declared `reversibility`/`reversibility_final`,
derive a check from the actual diff (paths touched, size) and flag mismatches.
Trigger: 2+ runs where `reversibility != reversibility_final` in `runs.jsonl` — first
measurable now that Step 1 landed.
Status: 0 runs recorded.

## Candidate 7 — Structural floor expanded (new deps, IaC, public endpoints, API contracts)

Idea: extend the sensitive-glob list beyond the current set to catch more escalation-worthy
surfaces.
Trigger: 2+ runs where `floor_triggered: none` but the Critic still reported a `[HIGH]`
finding on a surface the current globs don't cover.
Status: 0 runs recorded.

## Candidate 8 — Evict the sequential `steps.md` ledger — RESOLVED 2026-08-22

Outcome: **superseded, not evicted.** Neither trigger ever fired. The 2 recorded non-activations
(2026-08-21, runs `e52bc9dd` and `335de855`) both came from input the human had already
decomposed into 11 numbered slices, where that numbering *was* the ledger — so they never
counted toward the evict trigger, and the record should not pretend otherwise.
What removed the file was a design change, not the evidence: the Plan already lists the steps,
so a step's progress belongs there. Marking a step done in `.iamlazy/plan.md` and appending its
result under it collapses two artifacts into one and dissolves the next-gate overwrite
exception. The cut test survives unchanged. See PROJECT.md 2026-08-22.
Worth keeping from the old evidence: the second of those two runs averaged 163k context per turn
against 188k, ~13% cheaper per changed line. The handoff-by-file saving is real regardless of
which file carries it.

## Candidate 9 — Reinstate one delegated builder sub-agent

Idea: allow a single delegated writer alongside the Critic, reversing the 2026-08-20 exclusion.
Evidence FOR (2026-08-21), cost-weighted (`cache_read` × 0.1, `cache_write` × 1.25, `output` × 5),
main thread plus sub-agents, normalized by changed lines:

| Run | sub-agents | weighted | lines | per line |
|-----|-----------|----------|-------|----------|
| V2.3 `d7508d76` | 6 (builders + Critic) | 11.18M | 3401 | **3,287** |
| V2.4 `e52bc9dd` + `335de855` | 1 each (Critic only) | 18.23M | 3312 | **5,504** |

The delegated configuration came out **1.67x cheaper per changed line**.
Evidence AGAINST: V2.3 logged `retries: 1` and `human_interventions: 2` on both runs, against
`retries: 0` on both V2.4 runs — and `retries` survived the field audit below, so that contrast
is real, not self-flattery. Delegation may buy tokens and pay in rework. Also: the two features
differ in complexity, so this is an observation, not a controlled experiment.
Trigger: a controlled pair (same class of feature, one run each way), or 3+ runs showing >1.5x
cost per changed line in the single-thread direction.
Status: 1 uncontrolled observation. The exclusion stands (PROJECT.md 2026-08-20).

## Field audit — self-reported log fields (2026-08-21)

Audited against real transcripts across 5 sessions. Corrects the blanket expectation in
PROJECT.md's Debt section that self-reported fields degrade generally:

- **`critic_findings_count` — PASSES.** `335de855` reported 6; the Critic's own verdict says
  "four LOW and two INFO" = 6. Exact.
- **`retries` — PASSES (consistent).** V2.4 runs: one Critic invocation each, gate approved,
  `retries: 0`. `d7508d76`: 6 sub-agent transcripts, `retries: 1`. No contradiction found.
- **`human_interventions` — UNDERCOUNTS.** `1f1314b3` reported 1 against at least 3 real ones
  (a language correction, a tool-use interrupt, a config decision). `e48d685e` reported 0 with
  3 genuine human messages. `335de855` reported 1, defensible if only interrupts count — the
  field's definition is ambiguous, which is the actual defect.

Refined pattern: introspection fails when the field requires **estimating a quantity**
(`tokens_total`) or when its **definition is ambiguous** (`human_interventions`). It holds when
the model counts **discrete artifacts it produced** (`critic_findings_count`, `retries`).
Derivable replacement available: `[Request interrupted by user for tool use]` is a literal
transcript marker — 1 in `1f1314b3`, 1 in `335de855`, 0 elsewhere. Countable by command, like
`git diff --stat`.

## Candidate 10 — Critic decorrelated from the builder (origin: cross-model review round, 2026-08-22)

Idea: pick `*_CRITIC_MODEL` for **independence from the builder**, not for tier. A Critic that
shares a model with the builder shares its blind spots — it cannot see what the builder could
not see. The current ADR ("strongest for both roles") optimizes sharpness; this optimizes
decorrelation. Note the asymmetry: OpenCode can cross providers for free, Claude Code is
Anthropic-only, so there the knob is tier, not family — and lowering the Critic's tier
contradicts the fact that it produces 2–6 findings per run.
Also corrects a stale premise: the ADR justified one model with "the Critic only fires on the
least reversible work — rare enough". It is not rare. 12 of 28 logged runs escalated it to a
subagent, because the post-diff size floor fires far more often than the declared tier does.
Prerequisite resolved 2026-08-22: `runs.jsonl` now records a derived `critic_model`, so both
triggers below became measurable. Until runs accumulate under more than one value, neither can
fire — the field has to vary before it can discriminate.
Trigger A: 2+ runs where a `[HIGH]` or `[MEDIUM]` finding lands on code a previous Critic
already reviewed and passed — a shared blind spot, observable as a regression the review missed.
Trigger B (cheaper, deliberate): one controlled pair — the same diff reviewed twice, once by a
Critic sharing the builder's model and once by a different one — comparing unique findings.
Status: 0 occurrences. No `critic_model` recorded yet.
## Candidate 12 — The reversibility tier barely discriminates (origin: 28-run audit, 2026-08-22)

Idea: reversibility is the harness's central dial — it sets artifacts, gate and Critic. Across 28
logged runs it took `medium` 22 times, `high` 5, `low` 1, and of the 27 that record
`reversibility_corrected` it is `false` in all 27 — never once did the human disagree with the
estimate, and no run has ever recorded `true`. Worse for the
dial's stated job, all 12 subagent reviews line up with `floor_triggered: size`, not with the
tier — so the Critic is already being driven by the post-diff floor, and the tier's remaining
real effect is the gate. A dial with one dominant value is a constant with extra steps.
Two readings, and the log cannot separate them: either the tier is a poor discriminator, or the
sample is homogeneous — these 28 runs are mostly medium-sized features in two projects, which is
genuinely what `medium` means. Sampling caveat, same discipline as Candidate 8: a distribution
concentrated on the correct value is not a broken dial.
Do not act on the count alone. If it does turn out to be a poor discriminator, the fix is to
sharpen the criterion or collapse the tier to what still has an effect (gate / no gate) — not to
add a fourth level.
Trigger A: 20 further runs in which `reversibility` takes at most 2 distinct values AND every
`critic_mode: subagent` is explained by `floor_triggered`, i.e. the tier changed no outcome.
Trigger B: 2+ runs with `reversibility_corrected: true` — the opposite evidence, that the human
does disagree and the dial carries real signal worth keeping.
Status: 0 runs recorded under either trigger (the 28 predate it).

## Candidate 13 — The gate has never rejected anything (origin: 28-run audit, 2026-08-22)

Idea: of the 27 runs recording `gate_verdict` (one omits the field), 22 are `approved`, 1
`edited`, 4 `n/a`, and **0 are `rejected`**. The plan gate is the harness's main safety
mechanism and it has never once stopped a plan.
Three explanations fit the data equally well, which is exactly the problem: the plans really are
good; the human approves without reading closely; or rejecting is expensive (it means redoing
A1-A3) so editing-in-place wins by default. `gate_verdict` cannot tell these apart, and the
field is self-reported besides — the model records its own gate as approved.
Deliberately no proposed fix. "Add friction to the gate" would be a cure invented before the
disease is identified, and A1's single-block rule exists precisely to avoid ceremony. What is
needed first is a way to tell the three explanations apart.
Trigger: 2+ runs where the Critic reports a `[HIGH]` finding whose cause was already visible in
the approved Plan — a defect the gate could have caught by reading. That is the falsifiable
version of "the human is not really reading", and it is checkable against `.iamlazy/plan.md`.
Status: 0 occurrences recorded.

## Rejected — lower the auto-compact window (evaluated 2026-08-22, not adopted)

Recorded so it is not re-proposed. Idea: shrink the host's auto-compact threshold so long
sessions compact themselves, attacking the ~97.6% of spend that is `cache_read`.
Rejected on three counts, in order of weight:
- **Compaction invalidates the prompt cache.** The turns after it pay `cache_write` (1.25x)
  instead of `cache_read` (0.1x) to rebuild — roughly 12x per token — so it only amortizes if
  many turns follow. Ending the session does the same thing and restarts from a genuinely small
  context (`PROJECT.md` + Plan), not from a 40-50k summary. The cheaper lever already exists.
- **Its failure mode is silent, and this harness exists to make drift loud.** If compaction
  drops the approved A3 and the model builds from a half-remembered plan instead of re-reading
  `.iamlazy/plan.md`, the diff still looks plausible and nothing flags it. The safety net is the
  baton rule — prose, not structure.
- **No evidence of the problem.** Zero compaction events across 28 logged runs.
Reconsider only if a run is observed where compaction fired and the handoff-by-file alternative
was not available.
