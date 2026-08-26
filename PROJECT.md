# PROJECT.md — iamlazy

Ground truth for this repo. iamlazy reads this at the start of every session and proposes updates
(diff first, human approves) when it learns something. Authoritative but correctable: if an
observation contradicts this file, that contradiction gets reported, not silently resolved.

## Purpose

iamlazy is a software-development harness for **Claude Code** (and, partially, OpenCode). It runs
**one task end to end** in one thread: analyse it, ask what must be asked, write a contract, get it
approved, execute it group by group, and hand it to a **different** reviewer.

It is explicitly **not** built to sustain multi-hour sessions. A long run is a symptom, not the
use case — the run that took 6995s produced 230 lines across 3 files after seven different
attempts, 24x worse per line than a normal run. The harness exists to make that visible and stop it.

## Stack and conventions

- **Pure bash + files.** Zero external deps (no MCP, no plugins, no npm/pip/**no jq**). `curl` only
  for the `curl | bash` install path.
- **bash 3.2 compatible** (macOS default): no `declare -A`, POSIX sh probes, no globs in `[ -f ]`.
  Enforced by CI, which runs `test.sh` under `/bin/bash` on macOS.
- **Prompts are markdown.** Single source (`core/`, `critic/`); `templates/*.frontmatter` wrap it.
  The installer composes `frontmatter + body` and projects `models.conf` into `model:`.
- **Hooks are bash scripts** reading a JSON payload on stdin, parsed with `grep`/`sed`.
- **Generated artifacts default to English**; user-facing chat is in the user's language.
- **Idempotency** via the `# iamlazy-managed` marker in each generated file's frontmatter.

## Architecture — two layers

**Layer 0 — guaranteed** (`hooks/`, opt-in via `install.sh --with-hooks`). Executed code the model
cannot bypass. Five scripts, ~230 lines:

| Hook | Event | Guarantees |
|---|---|---|
| `guard-agent.sh` | `PreToolUse` on `Agent`\|`Task` | only `iamlazy-critic` may be spawned |
| `open-run.sh` | `UserPromptSubmit` | run identity from the real payload; orphan recovery; refuses a permission bypass |
| `track-edit.sh` | `PostToolUse` on `Edit`\|`Write` | every edit appended to `.iamlazy/journal.md` |
| `flush-run.sh` | `Stop` | the log line is written, derived, never self-reported |

**Layer 1 — asked** (`core/iamlazy.md`, ≤200 lines). Judgement: analysis, questions, the contract,
surgical edits, what the reviewer receives, the close. Prose here is acceptable *because the task
is bounded* — the short logged run obeyed every prose instruction; the long ones did not.

Three files carry the work: `PROJECT.md` (durable model), `.iamlazy/contract.md` (the signed
contract), `.iamlazy/journal.md` (append-only trace).

## The rule that decides where something lives

Classify every rule by its **footprint**: can a command tell whether it was honoured?

- Yes, and it can be prevented → **guarantee**, Layer 0
- Yes, but only afterwards → **protocol**, Layer 1 with a verifier
- No → **style**, Layer 1, with no pretence of being law

**Nothing is promoted by being important.** The sub-agent rule was called an inviolable law and
violated 7 times in 2 runs, because importance is not a mechanism.

## Principles

Normative preferences that govern decisions — distinct from Invariants: an invariant states
what IS, a principle states what we PREFER. A contract that deviates from a principle must
declare the deviation and its justification; an undeclared deviation is an automatic reviewer
finding.

- Zero new dependencies without justification — bash + files stays the baseline.
- Structure over discipline: prefer platform-enforced mechanisms over prose rules.
- Additions to the core evict something: the ≤200-line budget is design pressure, not a number
  to negotiate. Mechanical accounting belongs in hooks, never in the budget.
- Harness changes are evidence-gated: ideas not adopted yet live in `DELTAS.md`, each with a
  trigger observable in `runs.jsonl`; a fired trigger prompts evaluation, never auto-adoption.
- Verify against the running build, not the documentation. The hooks docs say the sub-agent tool
  is `Task`; in this build it is `Agent`, and a matcher on `Task` would have failed silently.

## Invariants (do not break)

- The Critic sub-agent **never** has write/edit permission. Bash is read/test only.
- **The Critic is the only sub-agent a run may spawn** — enforced by `guard-agent.sh`, and an
  ambiguous parse denies rather than guesses.
- The reviewer **derives its own diff** from paths and a commit range. It is never handed diff
  text: the builder does not choose what its auditor sees.
- `PROJECT.md` is **never** edited without showing the diff and getting approval.
- No code before the human approves the contract, except on trivially reversible changes.
- `.iamlazy/contract.md` is persisted **verbatim as approved**. Ticking a group's box and
  appending its result is not rewording.
- A run **cannot close** while a changed file sits outside the declared `## Scope`.
- iamlazy must not run under a permission bypass — enforced by `open-run.sh` (exit 2).
- The installer **never** edits `settings.json`; `uninstall.sh` never deletes `runs.jsonl`
  or any `PROJECT.md`.
- Empty tool output is never treated as a confirmed negative (second independent method required).

## Debt and known risks

- **No live end-to-end run yet.** `test.sh` (50) + `test-hooks.sh` (39) cover install mechanics and
  every Layer 0 runtime decision, with the hook suite validated by mutation. What is still
  unexercised is a real `/iamlazy` run: the contract, the gate and the review remain correct by
  construction of the prompt. Layer 0 closed part of this debt — a script reading JSON on stdin is
  testable in a way a prompt never was — but not all of it.
- **Guarantee 5 (circuit breaker) is not built.** The trigger the log supports is cost per changed
  line (79,542 tokens/line on the run that got lost, against 3,287–5,504 normally). It needs the
  contract to exist first, which is why it was deferred rather than rushed.
- **Hooks can be switched off.** `disableAllHooks` exists. Layer 0 is proof against forgetting,
  not proof against a decision.
- **`settings.json` is the human's to edit.** `--with-hooks` installs the scripts and prints the
  block; merging JSON without `jq` over someone's own config is not a risk worth taking.
- **OpenCode has no Layer 0.** It keeps the permission-based gate and loses every guarantee above.
  Whether it stays a supported target is an open question.
- **Semantic log fields are not written yet.** `flush-run.sh` writes the mechanical skeleton;
  `task_summary`, `critic_findings` and `gate_verdict` still need a place on disk for the model to
  leave them. Until then the log line is guaranteed to exist but is incomplete.
- **OpenCode directory + frontmatter conventions are trusted from this machine.**
- **`curl | bash` requires `IAMLAZY_RAW_BASE`** pointing at a raw base URL; offline is clone+run.
- **The Critic's Bash is a discipline hole**: frontmatter denies write/edit, but Bash can write via
  shell. Accepted so the Critic can run tests; the prompt forbids writes.
