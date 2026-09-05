# PROJECT.md — iamlazy

Ground truth for this repo, read at the start of every session. Updates are proposed as a diff and
approved by the human. Authoritative but correctable: an observation that contradicts this file
gets reported, not silently resolved.

## Purpose

iamlazy is a software-development harness for **Claude Code** (and, partially, OpenCode). It runs
**one task end to end** in one thread: analyse it, ask what must be asked, write a contract, get it
approved, execute it group by group, and hand it to a **different** reviewer. It is explicitly
**not** built for multi-hour sessions — a long run is a symptom, not the use case. The run that
took 6995s produced 230 lines after seven attempts, 24x worse per line than a normal run; making
that visible and stopping it is the point.

## Stack and conventions

- **Pure bash + files.** Zero external deps (no MCP, no plugins, no npm/pip/**no jq**). `curl` only
  for the `curl | bash` path; `python3` only inside the installer, to merge settings JSON.
- **bash 3.2 compatible** (macOS default): no `declare -A`, POSIX sh probes, no globs in `[ -f ]`.
  Enforced by CI, which runs `test.sh` under `/bin/bash` on macOS.
- **Prompts are markdown.** Single source (`core/`, `critic/`); `templates/*.frontmatter` wrap it.
  The installer composes `frontmatter + body` and projects `models.conf` into `model:`.
- **Hooks read a JSON payload on stdin**, parsed with `grep`/`sed`/`awk`. Every helper in `lib.sh`
  declares its variables `local`: they share one process, and a helper leaking `tpath` into its
  caller corrupts the log line written after it.
- **Generated artifacts default to English**; user-facing chat is in the user's language.
  Idempotency via the `# iamlazy-managed` marker in each generated file's frontmatter.

## Architecture — two layers

**Layer 0 — guaranteed** (`hooks/`, installed and registered by default). Executed code the model
cannot bypass:

| Hook | Event | Guarantees |
|---|---|---|
| `open-run.sh` | `UserPromptSubmit` | run identity from the real payload; stale-run sweep; refuses a permission bypass; **injects the run's state into the model's context** |
| `guard-agent.sh` | `PreToolUse` `^(Agent\|Task)$` | only `iamlazy-critic` may be spawned |
| `guard-critic-bash.sh` | `PreToolUse` `^Bash$` | inside the Critic, Bash cannot write: redirections, file commands, in-place edits, git mutations, installs |
| `track-edit.sh` | `PostToolUse` on edit tools | every edit appended to `.iamlazy/journal.md`; the contract's location fixes `project_root` and `base_ref` |
| `flush-run.sh` | `Stop` | the log line is written, derived, never self-reported; **the scope gate speaks**; **circuit breaker** on dollars per changed line |
| `end-run.sh` | `SessionEnd` | a run that ends without closing is logged as `abandoned`, not lost |
| `subagent-done.sh` | `SubagentStop` | the review actually returned, and its `findings: H/M/L/I` tally |

`lib.sh` holds the shared helpers; `merge-settings.sh` is installer-only.

**Layer 1 — asked** (`core/iamlazy.md`, ≤200 lines). Judgement: analysis, questions, the contract,
surgical edits, what the reviewer receives, the close. Prose is acceptable here *because the task
is bounded* — the short logged run obeyed every prose instruction; the long ones did not.

Three files carry the work: `PROJECT.md` (durable model), `.iamlazy/contract.md` (the signed
contract), `.iamlazy/journal.md` (append-only trace). **Run state is per session**, under
`~/.iamlazy/active/<session_id>.json` plus three sidecars (`.untracked`, `.gate`, `.stage`); it
used to be one global file, which let an open run in one project govern every other session.

## The rule that decides where something lives

Classify every rule by its **footprint**: can a command tell whether it was honoured?

- Yes, and it can be prevented → **guarantee**, Layer 0
- Yes, but only afterwards → **protocol**, Layer 1 with a verifier
- No → **style**, Layer 1, with no pretence of being law

**Nothing is promoted by being important.** The sub-agent rule was called an inviolable law and
violated 7 times in 2 runs, because importance is not a mechanism. A guarantee that fires
**outside its domain, or in silence, is a defect**. And where both layers name the same thing —
stage banners, the commands the Critic may run — **a test compares them**: three separate bugs
came from the two drifting apart while each looked correct alone.

## What we measure, and what we do not

Exploration and review are **not** the waste: the reviewer costs ~2% of a run and has caught three
`[HIGH]` bugs that passing test suites did not. The wrong question is *"how long before it started
writing?"*; the right one is *"how much rework and repeated context did it avoid?"*. The waste the
harness targets is exploring **without converging**, a second review pass over an
**already-reviewed** diff, **rework** from an unchecked assumption, and **deterministic work done
by reasoning** — which is what Layer 0 moved into code.

## Principles

Normative preferences that govern decisions — distinct from Invariants: an invariant states what
IS, a principle states what we PREFER. A contract deviating from one must declare it with its
justification; an undeclared deviation is an automatic reviewer finding.

- Zero new dependencies without justification — bash + files stays the baseline.
- Structure over discipline: prefer platform-enforced mechanisms over prose rules.
- Additions to the core evict something: the ≤200-line budget is design pressure, not a number
  to negotiate. Mechanical accounting belongs in hooks, never in the budget.
- Harness changes are evidence-gated: ideas not adopted yet live in `DELTAS.md`, each with a
  trigger observable in `runs.jsonl`; a fired trigger prompts evaluation, never auto-adoption.
- Verify against the running build, not the documentation. The hooks docs say the sub-agent tool
  is `Task`; in this build it is `Agent`, and a matcher on `Task` would have failed silently.
- **Never write a count into prose.** Assertion totals, script counts and line counts go stale
  silently and this file is read first by every run. Measure them, or do not state them.

## Invariants (do not break)

- The Critic **never** writes: Write and Edit denied by frontmatter, Bash by
  `guard-critic-bash.sh`. Its prompt backticks only what it may run, so the suite checks they agree.
- **The Critic is the only sub-agent a run may spawn** — enforced by `guard-agent.sh`, and an
  ambiguous parse denies rather than guesses.
- Hooks act **only on the session that owns the run**. A payload without a `session_id` never
  triggers anything.
- The reviewer **derives its own diff** from paths and a commit range. It is never handed diff
  text: the builder does not choose what its auditor sees.
- Change accounting is measured against **`base_ref`**, pinned when the contract is written, and
  the hooks **never mutate the user's git index** — no `git add -N`, which broke `git stash`.
- `PROJECT.md` is **never** edited without showing the diff and getting approval.
- No code before the human approves the contract, except on trivially reversible changes.
- `.iamlazy/contract.md` is persisted **verbatim as approved**. Ticking a group's box and
  appending its result is not rewording.
- A run **cannot close** while a changed file sits outside the declared `## Scope`, and it is
  **told so**, naming the file — a gate that blocks in silence is one the model cannot obey. It
  blocks **only when the model claims to be closing**: refusing mid-run turns, where groups are
  open by design, would trap the session where the human cannot intervene.
- A contract run **cannot close before its review returns**. Every box ticked is necessary and
  never sufficient — Layer 1 puts review and close *after* the execution that ticks them.
- iamlazy must not run under a permission bypass — enforced by `open-run.sh` (exit 2).
- The installer edits **only** its own `hooks` entries in `settings.json`, after a backup and
  with validation; user settings and user hooks are never altered. `uninstall.sh` unregisters
  them again and never deletes `runs.jsonl` or any `PROJECT.md`.
- Empty tool output is never treated as a confirmed negative (second independent method required).

## Debt and known risks

- **Still no clean end-to-end run.** The suites cover install mechanics and every Layer 0 runtime
  decision, validated by mutation and run under both a C and a UTF-8 locale. What is still
  unexercised is a real `/iamlazy` run: the contract, the gate and the review remain correct by
  construction of the prompt.
- **Two channels are documented, not observed.** `Stop`'s `{"decision":"block","reason":…}` (the
  breaker and the scope gate emit it plus `systemMessage` plus stderr plus exit 2, so every
  documented channel agrees) and `SubagentStop` firing with the parent `session_id` (which
  `critic_done` and `critic_findings` depend on). Neither fired in the one real run so far. If
  `SubagentStop` is wrong the close falls back to the CLOSE banner — degraded accuracy, never a
  stuck run — but those fields stay silently empty. What **is** confirmed is `PreToolUse`'s
  `permissionDecisionReason`: the sub-agent denial reached the model, which read it and adapted.
- **The breaker rests on four measured runs, and the floors carry more weight than the ratio.**
  $0.08 per changed line is 2x the worst healthy run above the 50-line floor. Cost per line
  **falls as a run grows** ($0.065 at 27 lines, $0.023 at 156) because reading, planning,
  contracting and reviewing cost the same whatever the diff, so the rule is really "expensive AND
  unproductive" and small tasks are protected by the floors, not by the ratio. Four points from
  two projects is thin: if it fires on a run that was fine, the threshold is wrong, not the run.
  Thresholds are still hardcoded in `flush-run.sh`; only prices live in config.
- **Every number this harness reports about itself has been wrong once.** `tokens_total` (7/7 runs,
  removed); the weighted count (~4x, then again for being blind to the model — a Sonnet and an
  Opus token priced the same while costing 2.5x apart); `files_changed`/`lines_changed` (0 on real
  work whenever a run staged or committed). All four were caught by a human refusing a figure that
  felt wrong, never by a test. Cost is now reported in **dollars** (`cost_usd`, Critic included,
  `null` rather than partial when a model is missing from `prices.conf`), with the raw token
  components kept so any run can be repriced from the record.
- **`gate_verdict` stays underived** (it would come from `ExitPlanMode`, whose payload shape is
  unconfirmed). `runs.jsonl` carries three schema generations: `1` self-reported, `2` derived, `3`
  adds `base_ref`, `stage_reached`, `critic_findings`, the `abandoned` outcome and a per-run
  `human_interventions`; `4` swaps `tokens_weighted` for `cost_usd`. `/iamlazy-review` reports
  what each line has, never inferring across generations or converting between the two cost units.
- **Hooks can be switched off.** `disableAllHooks` exists. Layer 0 is proof against forgetting,
  not proof against a decision.
- **OpenCode has no Layer 0**, no tests, and its conventions are trusted from one machine. It is
  the largest untested surface in the repo and needs a decision, not more analysis.
- **`curl | bash` requires `IAMLAZY_RAW_BASE`**; offline is clone+run.
- **The Critic's Bash guard reads the command string, not the process.** It stops the shell from
  writing; it does not stop a program the Critic legitimately runs — `npm test` may create
  fixtures, and that is intended. The discipline hole is closed, the hermetic seal is not.

Why the current design is the way it is: `docs/decisions-2026-09.md` (the six unchecked
suppositions, the gate's timing, `base_ref`) and `docs/decisions-2026-08.md` (Layer 0's rollout).
