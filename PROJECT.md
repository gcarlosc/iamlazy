# PROJECT.md — iamlazy

Ground truth for this repo. iamlazy reads this at the start of every session and proposes updates
(diff first, human approves) when it learns something. Authoritative but correctable: if an
observation contradicts this file, that contradiction gets reported, not silently resolved.

## Purpose

iamlazy is a software-development harness for **Claude Code** and **OpenCode**. One main thread
produces **five artifacts** — Brief, Ground, Plan, Diff+deviation note, Close — across the full
loop: request → grounding → plan → implement → post-validation, on existing and new projects. Not
a pipeline of separate agents and not personas: the classic postures survive as a consequence of
each artifact's demands, not as prompt instructions.

## Stack and conventions

- **Pure bash + files.** Zero external deps (no MCP, no plugins, no npm/pip/jq). `curl` only for
  the `curl | bash` install path.
- **bash 3.2 compatible** (macOS default): no `declare -A`, POSIX sh probes, no globs in `[ -f ]`.
  Enforced by CI, which runs `test.sh` under `/bin/bash` on macOS.
- **Prompts are markdown.** Single source (`core/`, `critic/`); `templates/*.frontmatter` wrap it.
  The installer composes `frontmatter + body` and projects `models.conf` into `model:`.
- **Generated artifacts default to English**; user-facing chat is in the user's language.
- **Idempotency** via the `# iamlazy-managed` marker in each generated file's frontmatter.
- Global install (not per-project), one command, works for both tools.

## Architecture in 10 lines

1. `core/iamlazy.md` — the main prompt: 5 inviolable rules + 5 artifacts (**hard budget ≤250
   lines**; a new rule must evict another or become structure).
2. `core/iamlazy-review.md` — the `/iamlazy-review` body: reads the run log, sweeps DELTAS triggers.
3. `critic/iamlazy-critic.md` — the Critic sub-agent (read-only, fresh context; reads `.iamlazy/`
   artifacts from disk, re-runs the Plan's claim commands).
4. `templates/claude-code/*` and `templates/opencode/*` — frontmatter wrappers only.
5. The Critic is the **only** real sub-agent — low reversibility, or when the post-diff floor fires.
6. Everything else runs in one thread; artifacts hand off via a baton + re-reading disk sources.
7. Ground truth is each target project's `PROJECT.md`; per-task Ground/Plan live in `.iamlazy/`.
8. Ceremony is calibrated by **reversibility** (high/medium/low), not size or greenfield.
9. Observability: one JSON line per task in `~/.iamlazy/runs.jsonl` (tmp→flush).
10. `install.sh` / `uninstall.sh` manage global config; `test.sh` + CI assert the invariants.

## Decisions (mini-ADRs)

Consolidated 2026-08-22. Foundations are one line each — they are settled and the code shows the
detail. Recent entries keep their reasoning; evidence tables live in `DELTAS.md`, not here.
**An ADR records a decision that changes the design.** Implementation changes belong in the commit
message, the README and the prompt — writing one up per edit is what pushed this file past 290
lines in a single session.

**Foundations (2026-07)** — nine settled decisions (artifacts over postures, structure over
discipline, the post-diff floor, pre-verified claims, verbatim persistence, the Critic as sole
sub-agent, marker idempotency, Principles + evidence backlog, rendering discipline). Archived
in `docs/decisions-archive.md`.

**Instrumentation and cost (2026-08)**

- **The run log is a journal, not telemetry** (08-17, corrected 08-19 and 08-22). `runs.jsonl` is
  self-reported: useful for trends, not for auditing one run. `tokens_total` was dropped after being
  wrong in 7/7 runs (up to ~94x off) — it needs an external observer the no-runtime design forbids.
  `session_id` moved to A1 after a glob heuristic picked a stale session. Line-budget rule: a
  shape-line character increase costs ⌈Δchars/95⌉ lines, since context tracks characters.
- **Derivable beats self-reported** (08-22). The log was silently losing records: `cat tmp >> log`
  does not guarantee a trailing newline, so 5 of 28 objects were fused and unparseable. Fixed at
  both ends and the file repaired (backup `runs.jsonl.bak-20260822`). `timestamp` (21/28 had round
  `:00` seconds) now comes from `date -u`; `human_interventions` from counting the literal transcript
  marker; `outcome` is constrained, after 28/28 runs reported `success` and the field said nothing.
  Still self-reported by design: `critic_findings_count`, `retries`, `gate_verdict`, `reversibility`.
  Cost joined the derivable set as **`tokens_weighted`** — deliberately not the old `tokens_total`
  name, since it measures something else. Counts come from the session transcript via `grep`+`awk`,
  weighted (output ×5, cache_creation ×1.25, cache_read ×0.1), and feed both the log and A5's
  closing report. This reverses the 08-19 removal: `tokens_total` was dropped as needing "an
  external observer the no-runtime design forbids", but the transcript **is** that observer — only
  the *estimation* was impossible, not the measurement. It unblocks Candidates 9 and 10, whose
  triggers both compare cost per changed line and until now needed hand computation.
- **Session length is the real cost lever** (08-19). ~97.6% of spend is `cache_read` over accumulated
  context: cost per turn rose from ~100k (81–103 turns) to ~233k (447 turns). Splitting one long
  session into several short ones projects to roughly half the tokens — which only works if runs hand
  off by file. Every decomposition decision below follows from this.
- **Decomposition: cut on verification; the Plan is its own ledger** (08-19, revised 08-22). The cut
  test is *can one command verify the whole job?* — one command means one Plan, several independent
  verifications mean per-step delivery. The original design put step results in a separate
  `.iamlazy/steps.md`; that file is gone. Progress belongs in the artifact that already lists the
  steps, so a step is marked done in `.iamlazy/plan.md` with its result appended under it. Removed by
  supersession, not by Candidate 8's eviction trigger, which never fired.

**Models and delegation (2026-08)**

- **iamlazy is out of scope for the host's delegation rules** (08-20). The single-thread model was
  fiction under Claude Code: a global `CLAUDE.md` "Agent Teams Lite" block declares delegation
  triggers non-skippable, and a global file outranks a command prompt. Measured on 3 sessions,
  delegated *builder* agents cost 113% and 122% of their main session and never reach `runs.jsonl`.
  Resolution: a precedence clause outside the `gentle-ai:*` markers so a sync cannot regenerate it
  away. Honest limit: prose, not structure — denying `Task` would also kill the Critic. Detection is
  the fallback: any sub-agent transcript other than the Critic's is evidence of a violation.
  Percentages are cost-weighted (`cache_read` × 0.1); raw sums overstate spend ~4x.
  **Update 08-22:** the Agent Teams Lite block was removed from that global `CLAUDE.md` (archived
  to `~/.claude/docs/`), so on this machine the conflict no longer exists and the clause is a plain
  statement of the invariant rather than an override of a competing one. The honest limit still
  applies to any other host that declares its own delegation rules.
- **Model scope is the session, not `models.conf`** (08-22, supersedes "strongest for both roles",
  07-02/04). A command's `model:` frontmatter overrides for the **current turn only** — verified in
  the docs — and the gate IS a human turn, so `CC_MAIN_MODEL` covers the planner and the **session
  model** covers the builder. `CC_CRITIC_MODEL` is the exception: a subagent's model holds for its
  whole run. Determinism therefore comes from `"model"` in user or project `.claude/settings.json`,
  and the installer reports whether one is pinned. For planner/builder routing, Claude Code's native
  `opusplan` lands the switch exactly on the gate, which rides on plan mode — no second command
  needed, and a two-command split was evaluated and rejected for buying nothing beyond it. No
  OpenCode equivalent. The old rationale ("the Critic is rare") is refuted: 12 of 28 runs escalated.
  `critic_model` is now recorded (derived) so Candidate 10 — a Critic decorrelated from the builder —
  becomes measurable; it cannot fire until the field varies. Because `opusplan` switches models at
  the gate, A1 now states the running model (derived from the transcript, never guessed) and
  re-states it when it changes: an unannounced switch, or an expected switch that silently did not
  happen, is drift — and this harness exists to make drift visible.

**Self-verification (2026-08-22)**

- **The project checks itself instead of relying on memory.** Three mechanisms landed together
  because they share one failure mode: each depended on a human remembering. `./test.sh` — 42
  assertions, bash 3.2, coreutils only — asserts the declared invariants (the Critic's read-only
  frontmatter, the marker on every template, anti-clobber, uninstall never touching `runs.jsonl`,
  the core budget), and CI runs it on push across Linux and macOS plus a job forcing `/bin/bash`
  so the claimed bash 3.2 support is actually tested. `/iamlazy-review` sweeps every DELTAS
  trigger against the run log and reports which fired. Two details worth keeping: the `--model`
  test runs against a copy, since `persist_model` rewrites `models.conf` in place; and the suite
  was validated by mutation, not by going green. The same audit produced Candidates 12 and 13 —
  the reversibility tier is `medium` in 22 of 28 runs and was never corrected; the gate has
  produced 0 `rejected` verdicts ever — recorded as falsifiable triggers rather than fixes,
  since two readings fit each and the log cannot separate them.
- **Prose instructions get skipped; banners do not** (08-22, from the first real run of these
  changes). A 6-round task ignored two new instructions — declaring the running model, and the
  `cost` line in the closing report — while obeying every structural one, including the banner's
  Critic-mode qualifier. Both skipped items sat in prose inside a bullet and required an extra
  command to produce a datum the human had not asked for. This is the founding ADR's claim
  observed in the wild: prose discipline decays with session length, a required shape does not.
  Fix: the model and effort now ride **in every banner** (`── A3 — PLAN · opus-5 · high ──`),
  which also puts an `opusplan` switch exactly where it happens, and `cost` is marked never
  omitted. Anything else that gets skipped should move into a shape rather than be re-worded.
- Implementation the same day, listed not argued: A4 edits are surgical — match the file's style,
  never "improve" adjacent code or comments, add none of your own unless the file already uses
  them; validation now precedes the Critic in A5 (never
  spend a subagent on code that does not build); A3 names the Critic mode it expects by checking
  paths against the globs; A5 emits a `✓`/`✗` closing report on medium/low; A2 caps recon at ~10
  files / ~15 tool calls; founding decisions moved to `docs/decisions-archive.md`. Details live in
  the core prompt and the README.

**The Critic's job, sharpened (2026-08-23)**

- **Blast radius is the Critic's distinctive work.** The human can test whether a feature works;
  they cannot see what else depends on what changed. That is now an explicit review axis: for
  every symbol, partial, config key, column or route the diff touches, find its other callers
  across the repo and name which were checked — an unchecked caller is not a safe one. Implicit
  contracts count, and that is the point: run `b5b8d46c` changed `<option>` ordering that
  `WspPhoneNumber#next_responsible_id` silently depended on, and it cost the human six rounds to
  find, because a manual test passes right up until production. Axis 1 ("does it do what was
  asked?") duplicates what the human already verified by testing — known, deliberately left.
- **`critic_findings_count` → `critic_findings` "H/M/L/I".** The log recorded how many findings a
  review produced, never whether they were worth anything, so "does the Critic earn its cost?"
  was unanswerable. The one run ever audited was 4 LOW + 2 INFO — zero HIGH, zero MEDIUM:
  suggestive, not conclusive. The Critic now emits its own tally and keeps the four severity tags
  in English whatever the reply language, so the count is read rather than recounted. Prerequisite
  for calibrating the anti-condescension rule, which across 29 runs has never produced zero.

## Principles

Normative preferences that govern decisions — distinct from Invariants: an invariant states
what IS, a principle states what we PREFER. A Plan (A3) that deviates from a principle must
declare the deviation and its justification; an undeclared deviation is an automatic Critic
finding, in every Critic mode.

- Zero new dependencies without justification in the plan — bash + files stays the baseline.
- Structure over discipline: prefer platform-enforced mechanisms over prose rules.
- Additions to the core evict something: the ≤250-line budget is design pressure, not a
  number to negotiate.
- Harness changes are evidence-gated: ideas not adopted yet live in `DELTAS.md`, each with a
  trigger observable in `runs.jsonl`; a fired trigger prompts evaluation, never auto-adoption.

## Invariants (do not break)

- The Critic sub-agent **never** has write/edit permission. Bash is read/test only.
- **The Critic is the only sub-agent an iamlazy run may spawn** — on any host tool, regardless of
  that host's own delegation rules. Delegating a writer is drift, not an optimization.
- `PROJECT.md` is **never** edited without showing the diff and getting approval.
- On medium/low reversibility, **no code is written before the human approves the plan.**
- `.iamlazy/ground.md` and `.iamlazy/plan.md` are persisted **verbatim as approved at the
  gate** — never re-worded on the way to disk. Marking a Plan step done and appending its result
  under it is not re-wording: no approved line is ever rewritten.
- The post-diff structural floor (globs + size cap) is **never skipped or negotiated**.
- iamlazy installs **no hooks** and must not be run under `--dangerously-skip-permissions`.
- `uninstall.sh` **never** deletes `~/.iamlazy/runs.jsonl` or any `PROJECT.md`.
- Empty tool output is never treated as a confirmed negative (second independent method required).

## Debt and known risks

- **The harness's runtime behavior is still not executed anywhere.** `./test.sh` + CI cover the
  installer, composition and the file-level invariants (42 assertions). The 5 artifacts remain
  correct *by construction of the prompt*: nothing exercises the gate, the Critic or the floor.
  This is the largest open risk in the project.
- **OpenCode directory + frontmatter conventions are trusted from this machine** (`agents/`,
  `commands/`, `mode:`, `permission:`). If OpenCode changes these, the installer needs updating.
- **`curl | bash` requires `IAMLAZY_RAW_BASE`** pointing at a raw base URL; offline is clone+run.
- **The run log assumes one active session at a time** (tmp→flush orphan recovery).
- **Bypass detection is not enforceable from inside a prompt.** The gate's strength on Claude Code
  comes from plan mode; on OpenCode from `permission: edit: ask` plus the tool's native prompts.
- **The Critic's Bash is a discipline hole**: frontmatter denies write/edit, but Bash can write via
  shell. Accepted so the Critic can run tests; the prompt forbids writes.
- **Some log fields stay self-reported**: `critic_findings_count`, `retries`, `gate_verdict`,
  `reversibility`. The 2026-08-21 audit found the first two reliable — introspection holds when the
  model counts discrete artifacts it produced, and fails when it must estimate a quantity or the
  definition is ambiguous. Everything derivable now is. Per-field evidence in `DELTAS.md`.
- **Self-report does not guarantee follow-through**: `.iamlazy/` sat tracked in this repo's own
  history until 2026-08-19 because a prior session started the fix and never committed it.
