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

Fields a `[log]` trigger may use today (schema 8): `host`, `duration_seconds`,
`human_interventions`, `files_changed`, `lines_changed`, `cost_usd`, `models_seen`,
`hooks_version`, `tokens_output` / `tokens_cache_write` / `tokens_cache_read`, `project_md`,
`stage_reached`, `critic_findings`, `close_detected_via`, `drift_thresholds`, `drift_fired`,
`outcome`, `base_ref`.

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
Trigger `[log]`: **unblocked 2026-09-11** — `models_seen` now records which models answered a run
and how often, so a run where builder and Critic shared one model is readable from the log.
Fires on 2+ runs whose `models_seen` names a single model.
Trigger `[human]`: a controlled pair — the same diff reviewed twice, once by a Critic sharing the
builder's model and once by a different one — comparing unique findings.
Status: 0 recorded. The `[log]` half was unmeasurable until the field existed; it has no history
behind it, so it starts counting from the runs logged after that date, not before.

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

## Candidate 15 — The close report renames the Critic's severities (origin: run audit, 2026-09-11)

The Critic's prompt declares exactly four tags, `[HIGH]`/`[MEDIUM]`/`[LOW]`/`[INFO]`, and a final
`findings: H/M/L/I` tally. The close report the human reads renames them. Measured in the OpenCode
store across the logged `iamlazy` sessions, two undeclared vocabularies, one appearance each:

- `0 critical / 0 major / 0 minor / 0 nit`
- `0 high / 0 low / 1 info`

Same shape as Candidate 14: the model inventing vocabulary at runtime where the prompt declared a
closed set. The damage is narrower than D5's, and worth stating precisely — **`runs.jsonl` is not
affected**. `critic_findings` is parsed by `subagent-done.sh` from the Critic's own final message,
so the logged tally stays canonical; it is the human-facing sentence that drifts. In one of the two
cases the rendering also dropped a count, reporting "0 findings" over a logged `0/0/0/1`.

Why no fix is proposed: a static test cannot catch this. The existing Layer 0 / Layer 1 agreement
tests compare two artifacts on disk — they cannot see a word the model chooses mid-run. Enforcing
the vocabulary would have to live in Layer 1 prose, which is where D5 has already failed three
times, so doing it again without evidence would repeat a known-bad move.

Trigger `[human]`: 2+ runs where the renamed severities actually mislead — a human reads the close
report and comes away with the wrong count or the wrong urgency. **Not** fired by the rename alone:
`critical` instead of `[HIGH]` costs nothing if the number and the meaning survive.
Status: 2 renames recorded, 1 with a dropped count; 0 cases of a human being misled.

## Candidate 16 — Ship a planner agent so OpenCode's model split is portable (origin: 2026-09-11)

On OpenCode the planner and the builder share a model, and not by choice. An agent's frontmatter
`model:` pins that agent, so `OC_MAIN_MODEL` holds for the `iamlazy` agent; the gate then sends
analysis to OpenCode's built-in `plan` agent, which pins **no** model and therefore inherits the
live session model — the one entering `iamlazy` just set. Measured: 15 planner messages on
`kimi-k2.7-code` while the configured OpenCode default was `deepseek-v4-pro`. Setting that default
does not fix it.

Today's answer is one block in the human's own `opencode.json`, verified to resolve:
`"agent": { "plan": { "model": "..." } }`. It works, and it is not portable — a second machine, or
anyone else installing iamlazy, gets the collapsed split silently.

Idea: ship `iamlazy-plan`, a primary agent pinned to a new `OC_PLAN_MODEL`, and point the gate at
it instead of OpenCode's built-in `plan`. The split would then live in `models.conf` like Claude
Code's does, and the installer would never need to touch user config.

Cost, stated so it is not discovered late: a third agent and template, a new `models.conf` knob,
a rewrite of `templates/opencode/gate.md`, tests for the new agent, and re-earning the built-in
plan agent's read-only guardrails — which are the reason the gate rides it in the first place.

Trigger `[log]`: 2+ OpenCode runs whose `models_seen` names one model where two were configured —
the collapse, which used to be invisible until someone thought to check, is now in the log.
Trigger `[human]`: the `opencode.json` block becomes a real cost — a second machine to configure,
or someone else installing iamlazy and getting the collapsed split without noticing.
Status: 0 recorded. One machine, configured by hand, deliberately.

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

## Candidate 17 — The close banner names a model that did not write it (origin: 2026-09-11)

Found within minutes of `models_seen` existing, which is the argument for having built it. The
README promises every artifact banner carries "the model and effort that produced it — read from
the session transcript, never guessed". Measured against the transcript of the `--lang=it` run
(session `7f32cddc`): `ANÁLISIS` and `CONTRATO` both declared `claude-opus-5` and were both really
written by it, while `CIERRE` declared `claude-opus-5` **twice** and was really written by
`claude-sonnet-5` both times. Under `opusplan` the switch happens at the gate, so by the close the
banner is repeating the model from before it — the exact case the banner exists to make visible is
the one it gets wrong, and it reads as authoritative either way.

Idea: derive the close banner's model the way the cost is derived, or stop printing a model there
rather than print a stale one. An honest omission beats a confident wrong value — the standing
rule in `PROJECT.md`, applied to the one number a human reads on every single run.

Trigger `[log]`: 2+ runs whose `models_seen` names a model the close banner did not, on a host
where the banner claims to be derived. Now checkable; it was not before.
Status: 1 recorded (session `7f32cddc`, both of its close banners).

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
| 19 | V1's plugin shape cannot load on a real OpenCode 2.x daemon | **Delivered 2026-09-17.** `install.sh` reads `opencode --version` before writing anything: on 2.x, `auto` drops the OpenCode half (and still installs the rest), an explicit `--tool` exits with the remedy, and an unreadable version installs V1 unchanged — no evidence is not evidence of 2.x. `--check` compares adapter shape against the daemon in both directions, prospectively, instead of waiting for a load failure to reach the log. Auto-promoting V2 on 2.x was deliberately NOT adopted: it would invert the "never auto-select V2" decision and fail without `bun`. The registry audit that scoped this is in `docs/decisions-2026-09.md`. |
| 18 | OpenCode's Layer 0 goes inert the moment a human answers in a new process | **Pruned 2026-09-16 — resolved by an upstream change, not a code fix.** Found against `v1.18.30`; the daemon this project actually runs is now `v2.0.1`. A real end-to-end run (opened via API on a CLI-created session, continued across three separate `opencode run --continue` processes, ~10 minutes) shows zero `session.deleted` events and a normal automatic close — `outcome:"flushed"`, real Critic findings. See `docs/decisions-2026-09.md`; superseded by Candidate 19, found while closing this one. |
