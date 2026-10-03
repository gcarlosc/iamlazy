# PROJECT.md — iamlazy

Ground truth for this repo, read at the start of every session. Updates are proposed as a diff and
approved by the human. Authoritative but correctable: an observation that contradicts this file
gets reported, not silently resolved.

**This file describes the system as it IS.** Why it got that way lives in `docs/decisions-*.md`,
which says so in its own opening line. Every session pays to read this one, so a paragraph earns
its place only by changing a future decision — anything that merely records what happened belongs
in the decision log, with a pointer from here.

## Purpose

iamlazy is a software-development harness for **Claude Code** and **OpenCode**. It runs **one task
end to end** in one thread: analyse it, ask what must be asked, write a contract, get it approved,
execute it group by group, and hand it to a **different** reviewer. It is explicitly **not** built
for multi-hour sessions: a long run is a symptom, not the use case, and making that visible and
stopping it is the point.

## Stack and conventions

- **Pure bash + files.** Zero external deps (no MCP, no npm/pip/**no jq**). `curl` only for the
  `curl | bash` path; `python3` only inside the installer, to merge settings JSON. **Declared
  exceptions**, both OpenCode adapters: `adapters/opencode/iamlazy.ts` imports only a type, erased
  by OpenCode's own Bun; `adapters/opencode-v2/iamlazy.ts` has a real `@opencode/plugin` dependency,
  build-time only, never at runtime. Bun is required to test either, never to run them.
- **bash 3.2 compatible** (macOS default): no `declare -A`, POSIX sh probes, no globs in `[ -f ]`.
  Enforced by CI, which runs `test.sh` under `/bin/bash` on macOS.
- **Prompts are markdown, one source.** `core/` + `critic/`, with `{{GUARANTEES}}` and `{{GATE}}`
  filled per host from `templates/<host>/`; the installer composes and projects `models.conf`.
- **Hooks read a JSON payload on stdin**, parsed with `grep`/`sed`/`awk`. Every helper in `lib.sh`
  declares its variables `local`: they share one process, and a helper leaking `tpath` into its
  caller corrupts the log line written after it.
- **Language splits by AUDIENCE, not by file.** What the MODEL and contributors read stays English:
  `core/`, `critic/`, templates, this file, code comments, `adapters/*/README.md`. What a HUMAN
  reads while operating the harness is Spanish: hook-emitted block and breaker reasons, the
  installers' printed output, and `README.md` in full. **Neutral Spanish, no voseo, no accents** —
  the ASCII rule is not taste, this project has shipped encoding bugs in exactly these strings.
  **Declared exception:** `guard-critic-bash.sh` stays English; its reader is the Critic, a model
  whose own prompt is English. A source invariant in `test.sh` fails the suite on an accented byte
  or a voseo form in anything a hook emits, and pins the close banner's box-drawing character as a
  literal. Standards asserted but unmeasured are how the 2026-09-18 migration missed three files.

## Architecture — two layers

**Layer 0 — guaranteed** (`hooks/`, installed and registered by default). Executed code the model
cannot bypass; `lib.sh` holds the shared helpers and `merge-settings.sh` is installer-only. On
Claude Code the hooks are registered in `settings.json`; on OpenCode the same scripts are invoked
by the plugin, which is the registration there:

| Hook | Event | Guarantees |
|---|---|---|
| `open-run.sh` | `UserPromptSubmit` | run identity from the real payload; **snapshots HEAD and the untracked files at the open**; stale-run sweep; refuses a permission bypass; **injects the run's state into the model's context** |
| `guard-agent.sh` | `PreToolUse` `^(Agent\|Task)$` | only `iamlazy-critic` may be spawned, and asks before it does |
| `guard-critic-bash.sh` | `PreToolUse` `^Bash$` | inside the Critic, Bash cannot write: redirections, file commands, in-place edits, git mutations, installs |
| `track-edit.sh` | `PostToolUse` on edit tools | every edit appended to `.iamlazy/journal.md`; the contract's location fixes `project_root` and `base_ref`, which a contract written any other way also gets on the next Stop |
| `host-cost.sh` | OpenCode only, per completed message | a host that prices its own messages hands the figure over, with the model that wrote it; accumulated into the run's cost sidecar, never re-priced |
| `flush-run.sh` | `Stop` | the log line is written **exactly once**, derived, never self-reported; **the scope gate speaks**; **circuit breaker** on dollars per changed line, plus absolute ceilings on duration and cost |
| `end-run.sh` | `SessionEnd` | a run that ends without closing is logged as `abandoned`, not lost — **exactly once**, same claim as a real close |
| `subagent-done.sh` | `SubagentStop` | the review actually returned, and its `findings: H/M/L/I` tally; for a background Critic, `flush-run.sh` reads both from the Critic's own files |

**Layer 1 — asked** (`core/iamlazy.md`, ≤200 lines). Judgement: analysis, questions, the contract,
surgical edits, what the reviewer receives, the close. Prose is acceptable here *because the task
is bounded* — the short logged run obeyed every prose instruction; the long ones did not.

Three files carry the work: `PROJECT.md` (durable model), `.iamlazy/contract.md` (the signed
contract), `.iamlazy/journal.md` (append-only trace). **Run state is per session**, under
`~/.iamlazy/active/<session_id>.json` plus its sidecars (`.untracked`, `.gate`, `.stage`,
`.findings`, `.cost`, `.opened`); it used to be one global file, which let an open run in one project govern
every other session.

## The rule that decides where something lives

Classify every rule by its **footprint**: can a command tell whether it was honoured?

- Yes, and it can be prevented → **guarantee**, Layer 0
- Yes, but only afterwards → **protocol**, Layer 1 with a verifier
- No → **style**, Layer 1, with no pretence of being law

**Nothing is promoted by being important.** The sub-agent rule was called an inviolable law and
violated repeatedly, because importance is not a mechanism. A guarantee that fires **outside its
domain, or in silence, is a defect**. And where both layers name the same thing — stage banners,
the commands the Critic may run, **what each host actually enforces** — **a test compares them**:
several separate bugs came from the two drifting apart while each looked correct.

## What we measure, and what we do not

Exploration and review are **not** the waste: the reviewer costs a small fraction of a run, and on
the one run where its findings were audited against the diff it caught real `[MEDIUM]` defects a
passing suite did not — a permission-gate bypass among them, on a change that looked too small to
review (`docs/decisions-2026-09.md`, 2026-09-11). No run has ever logged a `[HIGH]`. The wrong
question is *"how long before it started writing?"*; the right one is *"how much rework and
repeated context did it avoid?"* — **and nothing measures that yet**, which is the largest open
question about this harness. The real waste is exploring **without converging**, re-reviewing an
**already-reviewed** diff, **rework** from an unchecked assumption, and **deterministic work done
by reasoning** — what Layer 0 moved into code.

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
  is `Task`; in this build it is `Agent`, and a matcher on `Task` would have failed silently. The
  OpenCode SDK's types lag its runtime: its store is the source, not its `.d.ts`.
- **Never write a count into prose.** Assertion totals, script counts and line counts go stale
  silently and this file is read first by every run. Measure them, or do not state them. This
  applies to claims about the harness's own results, which is where it has failed: a `[MEDIUM]`
  finding was restated here as `[HIGH]` and stood until someone checked it against the log.

## Invariants (do not break)

- The Critic **never** writes: Write and Edit denied by frontmatter, Bash by
  `guard-critic-bash.sh`. Its prompt backticks only what it may run, so the suite checks they agree.
- **The Critic is the only sub-agent a run may spawn** — enforced by `guard-agent.sh`, and an
  ambiguous parse denies rather than guesses. A background spawn is refused outright: its findings
  would never reach the close gate.
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
- A run **cannot close** with a changed file outside the declared `## Scope`, and is **told so**,
  naming the file — but only when it claims to be closing. A gate that blocks in silence cannot be
  obeyed; one that blocks mid-run, where groups are open by design, traps the human out.
- A contract run **cannot close before its review returns**, a review still running in the
  background included, unless the human **declines** the
  Critic when asked — and **the decline must be real**: `guard-agent.sh` records that it actually
  asked, so a close claiming a decline nobody was asked for stays blocked. Every box ticked is
  necessary and never sufficient; Layer 1 puts review and close *after* the execution that ticks
  them.
- **The prompt never promises what its host does not enforce.** `{{GUARANTEES}}` is filled per
  host, and each host's text names the hooks it runs: the suite compares Claude Code's against
  `settings.json`'s registrations and OpenCode's against what the adapter invokes.
- **The OpenCode adapters translate and never decide.** They read no contract, compute no scope
  and know nothing about the breaker; `Scope`, `base_ref`, `DRIFT` and `CIERRE` never appear in
  them, and the suite fails if one does. Both adapters invoke an identical hook set, also tested.
- iamlazy must not run under a permission bypass — enforced by `open-run.sh` (exit 2) on Claude
  Code; OpenCode has no such mode, and its prompt says so.
- The installer edits **only** its own `hooks` entries in `settings.json`, after a backup and
  with validation; user settings and user hooks are never altered. `uninstall.sh` unregisters
  them again and never deletes `runs.jsonl` or any `PROJECT.md`.
- Empty tool output is never treated as a confirmed negative (second independent method required).

## Debt and known risks

Open risks only. Anything confirmed, closed or merely historical lives in the decision logs.

- **Check any figure this harness reports about itself.** Every figure it has ever reported was
  wrong at least once, and a human refusing a number that felt wrong found them — no test did.
  Cost is now `cost_usd`: model-aware, Critic included, `null` rather than partial when a model is
  missing from `prices.conf`, with raw token components kept so a run can be repriced from the
  record. Calibration history: `docs/measurement-history.md`.
- **The breaker's floors carry more weight than its ratio.** $0.08/line rests on four runs from two
  projects, and the two absolute ceilings (`DRIFT_MAX_SECONDS` 1h, `DRIFT_MAX_COST` $10) on the 21
  closed runs logged when they were added. If one fires on a run that was fine, the threshold is
  wrong, not the run. All default in `flush-run.sh`, are overridable in `~/.iamlazy/config`, share
  one `drift_warned` flag (one block per run, never two), and log both what was in effect and
  which ceiling tripped (`drift_reason`, schema 9).
- **`gate_verdict` stays underived** — it would come from `ExitPlanMode`, whose payload shape is
  unconfirmed. `runs.jsonl` carries several schema generations; `/iamlazy-review` reports what each
  line has and never infers across them.
- **Hooks can be switched off.** `disableAllHooks` exists. Layer 0 is proof against forgetting,
  not proof against a decision.
- **The Critic's Bash guard reads the command string, not the process.** It stops the shell from
  writing; it does not stop a program the Critic legitimately runs — `npm test` may create
  fixtures, and that is intended. The discipline hole is closed, the hermetic seal is not.
- **On OpenCode, two channels remain unconfirmed** because nothing ever got far enough to trigger
  them: whether a `throw` shows its reason to the model, and whether the gate's block fed back
  through `session.promptAsync` makes it continue. The `hk_ask` output also degrades to an allow
  there — its adapter only recognises `deny` — so the Critic always runs on that host.
- **The two OpenCode plugin APIs are not interchangeable**, and each daemon major accepts only its
  own shape. `install.sh` reads `opencode --version` before writing: on a 2.x daemon `auto` drops
  the OpenCode half, while an explicit `--tool` exits with the remedy. V2 is never auto-selected
  and needs `bun` to build. Both official default channels still serve 1.x, so V1 is not dead code.
- **`curl | bash` requires `IAMLAZY_RAW_BASE`**; offline is clone+run.

Why the design is what it is — every confirmation, reversal and closed gap:
`docs/decisions-2026-09.md` (Layer 0's hardening, the OpenCode ports, the installer's version
guard), `docs/decisions-2026-08.md` (Layer 0's rollout), `docs/measurement-history.md` (every
number that was wrong, and the breaker's calibration).
