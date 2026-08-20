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
