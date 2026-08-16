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
