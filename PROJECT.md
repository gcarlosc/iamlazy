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

**Layer 0 — guaranteed** (`hooks/`, installed and registered by default). Executed code the model
cannot bypass. Five scripts, ~230 lines:

| Hook | Event | Guarantees |
|---|---|---|
| `guard-agent.sh` | `PreToolUse` on `Agent`\|`Task` | only `iamlazy-critic` may be spawned |
| `open-run.sh` | `UserPromptSubmit` | run identity from the real payload; orphan recovery; refuses a permission bypass |
| `track-edit.sh` | `PostToolUse` on `Edit`\|`Write` | every edit appended to `.iamlazy/journal.md` |
| `flush-run.sh` | `Stop` | the log line is written, derived, never self-reported; **circuit breaker** on cost per changed line |

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

## What we measure, and what we do not

Exploration and review are **not** the waste. Reading the right files is cheaper than editing the
wrong ones and redoing the work, and the reviewer costs ~2% of a run while having caught three
`[HIGH]` bugs that passing test suites did not. The wrong question is *"how long before it started
writing?"*; the right one is *"how much rework, repeated context and unnecessary code did it
avoid?"*.

What is actually waste, and what the harness targets:
- exploring **without converging** — re-reading files, re-deriving what `PROJECT.md` already says
- a **second review pass over an already-reviewed diff**, instead of only over the fix
- **rework** from building on an assumption that was never checked
- **deterministic work done by reasoning** — ids, paths, counts, thresholds, state transitions —
  which is exactly what Layer 0 moved into code

(This framing is convergent with what Gentle AI documents publicly about the same problem;
the Layer 0 principle — delegate the deterministic to a binary rather than spend model
reasoning on it — is the same conclusion reached independently here.)

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
- The installer edits **only** its own `hooks` entries in `settings.json`, after a backup and
  with validation; user settings and user hooks are never altered. `uninstall.sh` unregisters
  them again and never deletes `runs.jsonl` or any `PROJECT.md`.
- Empty tool output is never treated as a confirmed negative (second independent method required).

## Debt and known risks

- **First live run, 2026-08-26: the harness worked, the accounting did not.** It produced a
  working project (tests, PROJECT.md) and the Critic found a real `[HIGH]` that got fixed —
  a timestamp parse bug that silently dropped runs from the trend. Four Layer 0 bugs surfaced
  that no fixture could have caught, all from one wrong assumption — **`cwd` is not the
  project**. A session started in one repo can be told to build in another; the journal, the
  close, the scope gate and the breaker all accounted against the wrong tree. Fixed by having
  the contract's own location declare `project_root`. The lesson is about method, not code:
  every fixture encoded the same assumption as the implementation, so the suite could only
  confirm it.
- **The close-by-banner path was dead for a whole run.** The regex still looked for `A5` after
  the prompt was rewritten to emit `CIERRE`/`CLOSE`. Same Layer 0 / Layer 1 disconnect found
  and fixed once before; it recurred because nothing checks that the two agree. A test now
  pins the real banner, but the general problem stands.
- **`exit 2` blocks a Stop without surfacing its reason.** The breaker fired and the model
  never saw the message. `systemMessage` is the channel that reaches it; stderr is not.
- **Still no clean end-to-end run.** `test.sh` (50) + `test-hooks.sh` (39) cover install mechanics and
  every Layer 0 runtime decision, with the hook suite validated by mutation. What is still
  unexercised is a real `/iamlazy` run: the contract, the gate and the review remain correct by
  construction of the prompt. Layer 0 closed part of this debt — a script reading JSON on stdin is
  testable in a way a prompt never was — but not all of it.
- **The weighted token count was inflated ~4x until 2026-08-27.** A transcript records the same
  assistant message several times (streaming plus final), and the `grep | awk` sum counted every
  usage block. Real figures after de-duplicating by message id: 1,457,005 not 5,433,969 for
  iamlazy-stats; 561,234 not 2,260,810 for a 4-line change. Caught by the human refusing to
  accept a number that "felt too big for the task" — the same instinct that killed `tokens_total`
  in 2026-08-19. Two wrong token counts in one project: any figure the harness reports about
  itself should be checked against an independent calculation before it is trusted.
- **Cost per changed line penalises small tasks, and the floors are what save it.** A run has a
  fixed cost — read, plan, contract, review — that does not scale with lines. The alphabetical
  ordering run measured 395,048 weighted over 27 lines: a ratio of 14,631, above the 14,000
  threshold, on a run that was entirely healthy (231s, closed by contract, three real findings).
  It did not fire only because absolute spend stayed under the 1M floor. So the breaker is really
  "expensive AND unproductive", not "unproductive" — and the floor is carrying more weight than
  the ratio. Worth revisiting as a two-axis rule rather than one ratio with guards.
- **The circuit breaker's threshold is calibrated on one lost run.** 20,000 weighted tokens per
  changed line sits above the worst healthy run (5,504) and well below the lost one (79,542), with
  floors at 50 lines and 1M tokens so early analysis cannot trip it. One data point is one data
  point: if it fires on a run that was actually fine, the threshold is wrong, not the run.
- **Hooks can be switched off.** `disableAllHooks` exists. Layer 0 is proof against forgetting,
  not proof against a decision.
- **`settings.json` is the human's to edit.** `--with-hooks` installs the scripts and prints the
  block; merging JSON without `jq` over someone's own config is not a risk worth taking.
- **OpenCode has no Layer 0.** It keeps the permission-based gate and loses every guarantee above.
  Whether it stays a supported target is an open question.
- **Two log fields stay underived, on purpose.** `flush-run.sh` writes identity, timing,
  interventions, files/lines, `tokens_weighted`, and derives `task_summary` (from the contract's
  own `# Task`) and `project_md` (from the diff). `critic_findings` and `gate_verdict` are NOT
  derived: the Critic's `findings: H/M/L/I` tally lives inside a sub-agent tool result, and a
  plain transcript grep also matches the **example in the Critic's own prompt** — verified
  2026-08-25, it returned `0/1/3/0` from documentation rather than from a review. `gate_verdict`
  would come from `ExitPlanMode`, whose payload shape is still unconfirmed. This project already
  shipped a token count that was wrong in 7 of 7 runs; an absent field is honest, a confidently
  wrong one is not.
- **`runs.jsonl` carries two schema generations.** Pre-Layer-0 lines are self-reported; lines with
  `"schema_version": 2` are derived. `/iamlazy-review` is instructed to report what each line
  actually has and never to infer across generations.
- **OpenCode directory + frontmatter conventions are trusted from this machine.**
- **`curl | bash` requires `IAMLAZY_RAW_BASE`** pointing at a raw base URL; offline is clone+run.
- **The Critic's Bash is a discipline hole**: frontmatter denies write/edit, but Bash can write via
  shell. Accepted so the Critic can run tests; the prompt forbids writes.
