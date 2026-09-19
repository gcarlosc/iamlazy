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

Fields a `[log]` trigger may use today (schema 9): `host`, `duration_seconds`,
`human_interventions`, `files_changed`, `lines_changed`, `cost_usd`, `models_seen`,
`hooks_version`, `tokens_output` / `tokens_cache_write` / `tokens_cache_read`, `project_md`,
`stage_reached`, `critic_findings`, `close_detected_via`, `drift_thresholds`, `drift_fired`,
`drift_reason`, `outcome`, `base_ref`.

A field being listed is not the same as a field being able to answer the question asked of it.
`models_seen` is a per-RUN tally — which models answered and how often — and it cannot say which
of them answered as the builder and which as the Critic. A trigger phrased as "builder and Critic
shared a model" is unmeasurable against it, however well the field itself works (see Candidate 10).

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
Trigger `[log]`: ~~fires on 2+ runs whose `models_seen` names a single model~~ — **retired as
unmeasurable 2026-09-18**, one week after being declared unblocked. `models_seen` is a per-run
tally and does not attribute a model to a role, so a single-model run and a run where the Critic
merely shared the builder's model are indistinguishable in it. Worse, the reading is inverted on
Claude Code today: `models.conf` sets `CC_MAIN_MODEL` and `CC_CRITIC_MODEL` to the SAME
`claude-opus-5`, which is exactly the correlation this candidate is about — and all 7 measurable
runs still log two models, because under `opusplan` the builder drops to Sonnet after the gate.
The log reads "decorrelated" precisely where the configuration says "correlated". Now **blocked**
on the Critic's own model recorded as its own field; `subagent-done.sh` already fires on the
event that would know it.
Trigger `[human]`: a controlled pair — the same diff reviewed twice, once by a Critic sharing the
builder's model and once by a different one — comparing unique findings.
Status: 0 recorded, and the `[log]` half is now known to be unable to record any. The accidental
tier split from `opusplan` is not a decorrelation anyone chose, and it disappears the moment that
mode is not in use.

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

## Candidate 20 — The Critic's severity gates nothing (origin: repo audit, 2026-09-18)

`subagent-done.sh` parses the Critic's own `findings: H/M/L/I` tally and writes it to a sidecar.
Every consumer of that file was traced: `flush-run.sh` reads it once, to print it in the log line.
Nothing compares the H. A run whose Critic reports three `[HIGH]` closes exactly like one
reporting `0/0/0/0` — the close gate refuses an unticked group and an undeclared path, and waves
through the severity the review exists to produce.

Idea: block the close on `H > 0` unless the human acknowledges it, the same shape the scope gate
already uses — `decision:block`, the reason naming the count, warned once per blocker set.

What argues against doing it now, and it is the whole reason this is a candidate: **no run has
ever logged a `[HIGH]`.** Across the 14 runs carrying a tally the worst is a single `[MEDIUM]`
(`0/1/4/2`). A gate built for a case that has never occurred would ship untested against reality,
and this project's own history says the threshold would be wrong on first contact. There is also a
real design question underneath: a `[HIGH]` the human reads and consciously accepts is a normal
outcome, so the gate must have an acknowledgement path or it becomes a trap — and an
acknowledgement the model can grant itself is the `critic_asked` failure over again.

Trigger `[log]`: 2+ runs whose `critic_findings` shows a non-zero first number. Directly
derivable; the field is canonical because it comes from the Critic's own final message.
Trigger `[human]`: 1 run where a `[HIGH]` was reported, the run closed, and the problem reached
the repository — the falsifiable version of "the severity should have stopped something".
Status: 0 recorded in 14 runs with a tally.

## Candidate 21 — The security lens is decided in Layer 1 (origin: repo audit, 2026-09-18)

Whether the security lens applies is decided by the model, reading a glob list in
`core/iamlazy.md` and checking it against the paths it changed. By this project's own
classification rule — "can a command tell whether it was honoured? Yes, and it can be
prevented →
guarantee, Layer 0" — that is on the wrong layer. `track-edit.sh` already sees every edited path
as a hook, on `PostToolUse`; matching it against the same globs and recording the verdict is
mechanical work currently done by reasoning, which is the exact waste `PROJECT.md` names.

Idea: `track-edit.sh` sets `security_lens=1` on the run file when a changed path matches, and
`open-run.sh` injects it the way it already injects the run's state. The prompt would then be told
the lens applies rather than asked to work it out, and the log could finally say how often it did.

Why it is a candidate and not a fix: the failure is entirely **unmeasured**. Nothing in
`runs.jsonl` records whether the lens was applied, so there is no evidence the model ever gets it
wrong, and no way to check. Moving it to Layer 0 without that record would replace an unverified
judgement with an unverified mechanism — and this repo has shipped a confidently wrong derived
field before. The honest first step is smaller than the candidate: record the verdict, then see.
Note also that this and Candidate 7 are complementary, not alternatives: 7 widens the glob list,
this one moves who evaluates it. Adopting either does nothing for the other.

Trigger `[log]`: **blocked** on a field recording the lens verdict — none exists. Not
not-fired: unmeasurable until one does, per the rule at the top of this file.
Trigger `[human]`: 2+ runs where a security-relevant path was changed and the close report shows
the lens was not applied — readable from the transcript without any new field, which is why this
is the half that can actually count today.
Status: 0 recorded.

## Candidate 22 — `runs.jsonl` accumulates generations and duplicates (origin: audit, 2026-09-18)

65 lines carry 9 schema generations, and three of them are byte-identical: the
2026-09-14T00:31:24Z triple, written before `hk_claim_close` existed to stop concurrent plugin
instances each appending the same close. `/iamlazy-review` must understand every generation to
read its own history, and any count that sweeps the file counts that run three times.

Idea: a one-shot migration to the current schema plus a dedupe on `(session_id, timestamp)`.

Why not yet: the log is **designed** to tolerate this — "`/iamlazy-review` reports what each line
has and never infers across them" is a stated invariant, not an oversight, and it is what makes
old lines readable at all. A migration would rewrite history that is currently honest about being
partial, and the fields most worth comparing across time (`cost_usd`, `models_seen`,
`drift_reason`) did not exist in the old lines and cannot be invented for them. The duplicate
triple is already fixed at the source; what remains is three stale rows in a 65-row file.

Trigger `[log]`: the file passes ~200 lines, or a second duplicate group appears with a
`hooks_version` at or after the one that introduced `hk_claim_close` — the second is the one that
matters, because it would mean the fix did not hold.
Trigger `[human]`: a question about the harness's own history that cannot be answered because the
generations cannot be compared — the only real cost of leaving it alone.
Status: 3 duplicate rows, 9 generations, 65 lines. One duplicate group, from before the fix.

---

## Rejected — migrate to Pi as the sole host (evaluated 2026-09-10)

Recorded so it is not re-proposed without new evidence. The question was not adding Pi as a third
target — it was **replacing Claude Code and OpenCode with it**. Pi's own extension API is the best
of the three: typed `{block, reason}` tool denial, an explicit `turn_end` event where OpenCode
requires inferring turn boundaries from `session.idle`, `ctx.exec()` in place of raw shell
interpolation, and a `session_before_compact` hook that would finally make `compactions` derivable
— a field no host has ever been able to produce.

Rejected on usage alone, measured against the real logs, not against the technical comparison:

| Host | Assistant messages, last 30 days | Days used |
|---|---|---|
| Claude Code | 63,282 | 31 / 31 |
| OpenCode | 785 | 17 |
| Pi | 9 | 2, and both are from this evaluation itself |

Claude Code is where essentially all real work happens. Moving the harness to Pi would move it off
the host actually in use, onto one with no real sessions to speak of. The value of iamlazy is that
it runs where the work happens, not that its adapter is more elegant.

Two things worth keeping from the evaluation:

- **Pi has no built-in sub-agents, plan mode, or permission bypass** (its own docs say so
  explicitly) — a Pi port would mean building the Critic as a registered tool from scratch, not
  translating an existing primitive the way the OpenCode adapter does. This is construction, not
  adaptation, regardless of the decision above.
- **Its package.json declares an `./hooks` export pointing at a directory that does not exist.**
  Pi's own types lag its build the same way OpenCode's SDK types do — verify against the installed
  `dist/`, never the `.d.ts` in isolation, if this is ever revisited.

Reconsider only if real day-to-day usage shifts toward Pi on its own — not if it is adopted because
its API is better in the abstract.

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
