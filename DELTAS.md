# DELTAS.md — evidence-gated backlog

Ideas evaluated and deliberately **not** adopted, each behind a trigger. A fired trigger prompts
evaluation — never auto-adoption. When a candidate is adopted or discarded for good, its outcome
is recorded in one line and the entry is pruned.

**Every trigger declares how it is checked**, because `/iamlazy-review` sweeps this file against
`runs.jsonl` on every invocation:

- `[log]` — derivable from `runs.jsonl`. The review checks it and reports fired / not fired.
- `[human]` — needs a person to notice and say so. **The review must not try to derive these**,
  and must not report them as unconfirmable either; it lists them and moves on. Before this was
  labelled, the review spent a paragraph per run explaining it could not confirm them.

A trigger written against a field that no longer exists is **unmeasurable**, not unfired. Those
have been retired below rather than left to accumulate — 8 of 11 candidates were in that state on
2026-09-05, which made the whole sweep noise.

Fields a `[log]` trigger may use today (schema 6): `host`, `duration_seconds`,
`human_interventions`, `files_changed`, `lines_changed`, `cost_usd`, `tokens_output` /
`tokens_cache_write` / `tokens_cache_read`, `project_md`, `stage_reached`, `critic_findings`,
`close_detected_via`, `drift_thresholds`, `drift_fired`, `outcome`, `base_ref`.

---

## Candidate 1 — Quality checklist for the analysis (origin: spec-kit `/speckit.checklist`)

Idea: validate the QUALITY of the analysis — completeness, clarity, buried ambiguities — not just
its shape. "Unit tests for the natural-language requirement."
Trigger `[human]`: 2+ runs where an ambiguity nobody questioned before the gate caused rework
after it.
Status: 0 recorded.

## Candidate 2 — Coverage-driven questioning (origin: spec-kit `/speckit.clarify`)

Idea: the question block sweeps defined dimensions (actors, boundary states, error handling, data,
integrations, non-functionals) instead of free generation. Rescue the coverage taxonomy only —
spec-kit's one-question-at-a-time loop contradicts the single-block rule and is not a candidate.
Trigger `[human]`: same as Candidate 1; if it fires, evaluate both as one change.
Status: 0 recorded.

## Candidate 3 — Cap human-visible lists at ~5 items (origin: i-have-adhd rule 9)

Idea: split lists longer than ~5 into "do now" vs "later", so a block that is short in lines does
not still overwhelm a scanning reader.
Note (2026-09-05): the old premise, that the core capped the question block at 15 lines and the
plan at 30, is **stale** — those caps were removed. Nothing caps either dimension now.
Trigger `[human]`: 2+ runs where a long question or group list caused confusion or rework.
Status: 0 recorded.

## Candidate 7 — Widen the security lens (new deps, IaC, public endpoints, API contracts)

Idea: extend the glob list the core checks changed paths against before telling the Critic the
security lens applies.
Rewritten 2026-09-05: the original trigger used `floor_triggered`, a field that no longer exists —
the Critic used to be *escalated* by a post-diff floor and now runs on every task, so escalation
is moot. What survives is whether the glob list is wide enough.
Trigger `[log]` + `[human]`: 2+ runs whose `critic_findings` shows a `[HIGH]` **and** the human
confirms it landed on a security-relevant surface the globs in `core/iamlazy.md` do not name.
Status: 0 recorded.

## Candidate 10 — Decorrelate the Critic from the builder (origin: cross-model round, 2026-08-22)

Idea: choose the Critic's model for **independence from the builder**, not for tier. A Critic
sharing the builder's model shares its blind spots — it cannot see what the builder could not see.
Half of this resolved itself. The candidate was written when 58% of reviews ran on the main
thread, where `CC_CRITIC_MODEL` had no effect and builder and Critic were the same model by
construction. The Critic is now **always** a sub-agent, and a sub-agent's model holds for its whole
run, so that knob works. What remains is the case where the session model and `CC_CRITIC_MODEL`
happen to be equal. Note the asymmetry between hosts: OpenCode can cross *providers* for free;
Claude Code is Anthropic-only, so there the knob is tier, not family — and lowering the Critic's
tier contradicts the fact that it earns its cost.
Trigger `[log]`: **blocked** — needs a `models_seen` field, which is not derived yet. Until then
this cannot be measured, and saying otherwise would be pretending.
Trigger `[human]`: a controlled pair — the same diff reviewed twice, once by a Critic sharing the
builder's model and once by a different one — comparing unique findings.
Status: 0 recorded, and the `[log]` half is unmeasurable by construction.

## Candidate 14 — Stop the close depending on a stage name the model invents (origin: audit D5)

Idea: the close-by-banner path matches the exact token `CIERRE`/`CLOSE`, and the core declares six
stage names "never invented". The model keeps inventing them anyway. Two ways out, and they are
opposites, which is why this is a candidate and not a fix:

- **Enforce the list.** `hk_stage` is deliberately shape-based — it records whatever word sits in
  the banner position, so an undefined stage appears in the log as itself instead of vanishing.
  Matching against a closed list would hide the drift rather than record it, so enforcement would
  have to live in Layer 1, where it has already failed three times.
- **Stop depending on the banner at all.** The contract path already closes runs without it; the
  banner is the floor for the trivial path that has no ledger. Removing it means a trivial run can
  only close by TTL, which trades a loud failure for a silent one — the trade this project keeps
  refusing.

Trigger `[log]`: **already fired.** 2 of the 5 runs that recorded a `stage_reached` used a name the
core does not define — `EVALUACIÓN` (2026-09-05) and `RESPUESTA` (2026-09-07) — and `A5` did the
same before the field existed. Three occurrences, two of them measurable.

What makes it a candidate rather than a defect: **neither invented name broke a close.** Both runs
closed by contract, which is the path that does not read the banner. The damage so far is confined
to `stage_reached` being a name nobody can group by. Evaluate when a run actually fails to close
because its banner said something else, or when the log has enough invented names to make
`stage_reached` useless for comparison — whichever comes first.

## Candidate 13 — The gate has never rejected anything (origin: 28-run audit, 2026-08-22)

Observation, still the sharpest open question about the harness: across 29 logged runs the plan
gate produced 22 `approved`, 1 `edited`, 4 `n/a` and **0 `rejected`**. The main safety mechanism
has never once stopped a plan.
Three explanations fit equally well, which is the problem: the plans really are good; the human
approves without reading closely; or rejecting is expensive (it means redoing the analysis) so
editing in place wins by default.
Deliberately no proposed fix — "add friction to the gate" would be a cure invented before the
disease is named, and the single-block rule exists precisely to avoid ceremony.
Rewritten 2026-09-05: `gate_verdict` is no longer logged, so the count above cannot be extended.
Trigger `[log]` + `[human]`: 2+ runs where `critic_findings` shows a `[HIGH]` whose cause was
already visible in the approved `.iamlazy/contract.md` — the falsifiable version of "the human is
not really reading", checkable against the contract on disk.
Status: 0 recorded.

---

## Rejected — lower the auto-compact window (evaluated 2026-08-22)

Recorded so it is not re-proposed. Idea: shrink the host's auto-compact threshold so long sessions
compact themselves, attacking the ~97.6% of spend that is `cache_read`.
Rejected on three counts, in order of weight:

- **Compaction invalidates the prompt cache.** The turns after it pay `cache_write` (1.25x)
  instead of `cache_read` (0.1x) to rebuild — roughly 12x per token — so it only amortizes if many
  turns follow. Ending the session does the same thing and restarts from a genuinely small context
  (`PROJECT.md` + contract), not from a 40–50k summary. The cheaper lever already exists.
- **Its failure mode is silent, and this harness exists to make drift loud.** If compaction drops
  the approved contract and the model builds from a half-remembered plan instead of re-reading
  `.iamlazy/contract.md`, the diff still looks plausible and nothing flags it.
- **No evidence of the problem.** Zero compaction events observed across the logged runs.

Reconsider only if a run is observed where compaction fired and handoff-by-file was unavailable.

---

## Resolved and retired

Pruned 2026-09-05. Each was either delivered or written against a field the harness no longer
records; a backlog whose triggers cannot fire is cost without signal.

| # | Was | Outcome |
|---|---|---|
| 4 | `## Expected scope` block declaring paths up front | **Delivered.** The contract's `## Scope` section, enforced by `hk_scope_violations`. |
| 5 | Compare declared scope against the real diff, report drift | **Delivered**, and stronger than proposed: it does not report drift, it **blocks the close** until the deviation is declared or reverted. |
| 6 | Recompute `reversibility` from the real diff | **Retired.** The reversibility tier no longer exists in the harness. |
| 8 | Evict the sequential `steps.md` ledger | **Superseded** 2026-08-22 by a design change, not by its trigger, which never fired. Worth keeping: handing off by file measured ~13% cheaper per changed line. |
| 9 | Reinstate one delegated builder sub-agent | **Retired as unfalsifiable.** `guard-agent.sh` denies every sub-agent but the Critic, so the controlled pair can no longer be gathered passively. Reviving it means deliberately disabling the guard for an experiment — a decision, not a trigger. The one uncontrolled observation (delegation 1.67x cheaper per changed line, but with more retries and interventions) stands unresolved. |
| 12 | The reversibility tier barely discriminates | **Retired — the outcome it contemplated happened.** It proposed collapsing the dial to what still had an effect; the dial was removed entirely. |
| — | Field audit of self-reported log fields (2026-08-21) | **Absorbed.** Its conclusion — introspection fails when a field needs a quantity estimated or has an ambiguous definition — is now the standing rule in `PROJECT.md`, with the full record in `docs/measurement-history.md`. |
