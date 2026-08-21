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
motivated the **sequential A3 form** (adopted, see PROJECT.md 2026-08-19) — not this block
directly. Once large work decomposes into `T01…TN`, each step's own diff is the unit "scope"
should be checked against; evaluating a scope-drift mechanism before that existed would have
measured the wrong thing. Re-evaluate after a few sequential-form runs land.

## Candidate 5 — Scope drift comparator (origin: metrics-instrumentation session, Step 3)

Idea: compare A3's declared scope (Candidate 4) against A4's actual diff paths; report drift.
Trigger: written in observable terms only in the second measurement window, after Candidate 4
lands — the Step 1 baseline cannot measure scope drift (no declared scope exists yet).
Status: blocked on Candidate 4, which is itself now deferred behind the sequential A3 form
(2026-08-19) — see Candidate 4.

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

## Candidate 8 — Evict the sequential `steps.md` ledger

Idea: remove the `T01…TN` sequential form and its `.iamlazy/steps.md` ledger from the core,
reclaiming lines from the ≤250 budget. Adopted 2026-08-19 on the strength of 6/7 runs tripping
the 400-line floor — and not exercised once since.
Evidence (2026-08-21): V2.4 in git-diff-viewer was an 11-slice task where the model itself
proposed splitting ("this session = Slices 1-6, next session = Slices 7-11"). Two runs followed,
`e52bc9dd` (1-6) and `335de855` (7-11), and `.iamlazy/steps.md` was never created in either. The
handoff still worked — through the target project's `PROJECT.md` (`## Delivery status — V2.4
Slices 1-6 DONE`) plus a hand-written continuation prompt. Measured effect: the second session
averaged 163k context per turn against 188k, ~13% cheaper per changed line. So the model
resolves decomposition as a **scope cut**, not as the designed sequential form, and the ledger's
stated problem (nowhere to write a step's result) was already solved by an artifact that existed.
Trigger to evict: 1 more multi-step task where the model splits work without writing `steps.md`.
Trigger to keep: any run where `steps.md` is created AND a later step reads it.
Status: 2 non-activations recorded (2026-08-21).

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
