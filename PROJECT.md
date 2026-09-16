# PROJECT.md — iamlazy

Ground truth for this repo, read at the start of every session. Updates are proposed as a diff and
approved by the human. Authoritative but correctable: an observation that contradicts this file
gets reported, not silently resolved.

## Purpose

iamlazy is a software-development harness for **Claude Code** and **OpenCode**. It runs **one task
end to end** in one thread: analyse it, ask what must be asked, write a contract, get it approved,
execute it group by group, and hand it to a **different** reviewer. It is explicitly **not** built
for multi-hour sessions: a long run is a symptom, not the use case, and making that visible and
stopping it is the point.

## Stack and conventions

- **Pure bash + files.** Zero external deps (no MCP, no npm/pip/**no jq**). `curl` only for the
  `curl | bash` path; `python3` only inside the installer, to merge settings JSON. **Declared
  exceptions:** `adapters/opencode/iamlazy.ts`, the OpenCode V1 plugin. It translates OpenCode's
  events into the hooks' payloads and decides nothing — a test greps it for harness logic. Its
  only import is a type, erased by OpenCode's own Bun; Bun is required to run its tests, never
  at runtime. `adapters/opencode-v2/iamlazy.ts` is a second, not-yet-committed exception with a
  REAL npm dependency (`@opencode/plugin`, build-time only) — see the debt bullet below.
- **bash 3.2 compatible** (macOS default): no `declare -A`, POSIX sh probes, no globs in `[ -f ]`.
  Enforced by CI, which runs `test.sh` under `/bin/bash` on macOS.
- **Prompts are markdown, one source.** `core/` + `critic/`, with `{{GUARANTEES}}` and `{{GATE}}`
  filled per host from `templates/<host>/`; the installer composes and projects `models.conf`.
- **Hooks read a JSON payload on stdin**, parsed with `grep`/`sed`/`awk`. Every helper in `lib.sh`
  declares its variables `local`: they share one process, and a helper leaking `tpath` into its
  caller corrupts the log line written after it.
- **Generated artifacts default to English**; user-facing chat is in the user's language.
  Idempotency via the `# iamlazy-managed` marker in each generated file's frontmatter. This split
  by AUDIENCE, not by file: the composed prompts (`core/`, templates, this doc, code comments)
  stay English -- they are read by contributors and by the model regardless of who is running it.
  Everything a HUMAN reads while operating the harness is Spanish, matching this project's own:
  hook-emitted block/breaker reasons (`flush-run.sh`, `guard-agent.sh`, always were), and
  `install.sh`/`uninstall.sh`/`adapters/opencode-v2/build.sh`'s printed output (2026-09-14).

## Architecture — two layers

**Layer 0 — guaranteed** (`hooks/`, installed and registered by default). Executed code the model
cannot bypass; `lib.sh` holds the shared helpers and `merge-settings.sh` is installer-only. On
Claude Code the hooks are registered in `settings.json`; on OpenCode the same scripts are invoked
by the plugin, which is the registration there:

| Hook | Event | Guarantees |
|---|---|---|
| `open-run.sh` | `UserPromptSubmit` | run identity from the real payload; stale-run sweep; refuses a permission bypass; **injects the run's state into the model's context** |
| `guard-agent.sh` | `PreToolUse` `^(Agent\|Task)$` | only `iamlazy-critic` may be spawned, and asks before it does |
| `guard-critic-bash.sh` | `PreToolUse` `^Bash$` | inside the Critic, Bash cannot write: redirections, file commands, in-place edits, git mutations, installs |
| `track-edit.sh` | `PostToolUse` on edit tools | every edit appended to `.iamlazy/journal.md`; the contract's location fixes `project_root` and `base_ref` |
| `host-cost.sh` | OpenCode only, per completed message | a host that prices its own messages hands the figure over, with the model that wrote it; accumulated into the run's cost sidecar, never re-priced |
| `flush-run.sh` | `Stop` | the log line is written **exactly once**, derived, never self-reported; **the scope gate speaks**; **circuit breaker** on dollars per changed line |
| `end-run.sh` | `SessionEnd` | a run that ends without closing is logged as `abandoned`, not lost — **exactly once**, same claim as a real close |
| `subagent-done.sh` | `SubagentStop` | the review actually returned, and its `findings: H/M/L/I` tally |

**Layer 1 — asked** (`core/iamlazy.md`, ≤200 lines). Judgement: analysis, questions, the contract,
surgical edits, what the reviewer receives, the close. Prose is acceptable here *because the task
is bounded* — the short logged run obeyed every prose instruction; the long ones did not.

Three files carry the work: `PROJECT.md` (durable model), `.iamlazy/contract.md` (the signed
contract), `.iamlazy/journal.md` (append-only trace). **Run state is per session**, under
`~/.iamlazy/active/<session_id>.json` plus its sidecars (`.untracked`, `.gate`, `.stage`,
`.findings`, `.cost`); it used to be one global file, which let an open run in one project govern
every other session.

## The rule that decides where something lives

Classify every rule by its **footprint**: can a command tell whether it was honoured?

- Yes, and it can be prevented → **guarantee**, Layer 0
- Yes, but only afterwards → **protocol**, Layer 1 with a verifier
- No → **style**, Layer 1, with no pretence of being law

**Nothing is promoted by being important.** The sub-agent rule was called an inviolable law and
violated 7 times in 2 runs, because importance is not a mechanism. A guarantee that fires
**outside its domain, or in silence, is a defect**. And where both layers name the same thing —
stage banners, the commands the Critic may run, **what each host actually enforces** — **a test
compares them**: four separate bugs came from the two drifting apart while each looked correct.

## What we measure, and what we do not

Exploration and review are **not** the waste: the reviewer costs ~2% of a run and has caught three
`[HIGH]` bugs that passing suites did not. The wrong question is *"how long before it started
writing?"*; the right one is *"how much rework and repeated context did it avoid?"*. The real waste
is exploring **without converging**, re-reviewing an **already-reviewed** diff, **rework** from an
unchecked assumption, and **deterministic work done by reasoning** — what Layer 0 moved into code.

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
- A run **cannot close** with a changed file outside the declared `## Scope`, and is **told so**,
  naming the file — but only when it claims to be closing. A gate that blocks in silence cannot be
  obeyed; one that blocks mid-run, where groups are open by design, traps the human out.
- A contract run **cannot close before its review returns**, unless the human **declines** the
  Critic when asked to spawn it — that closes via the banner path, and the close report must
  declare the decline. **The decline must be real**: `guard-agent.sh` records that it actually
  asked, and a close claiming a decline that never happened stays blocked — a run closed once
  citing "the human decided" with zero attempts to spawn the Critic anywhere in its transcript.
  Every box ticked is necessary and never sufficient — Layer 1 puts review and close *after* the
  execution that ticks them.
- **The prompt never promises what its host does not enforce.** `{{GUARANTEES}}` is filled per
  host, and each host's text names the hooks it runs: the suite compares Claude Code's against
  `settings.json`'s registrations and OpenCode's against what the adapter invokes.
- **The OpenCode adapter translates and never decides.** It reads no contract, computes no scope
  and knows nothing about the breaker; `Scope`, `base_ref`, `DRIFT` and `CIERRE` never appear in
  it, and the suite fails if one does.
- iamlazy must not run under a permission bypass — enforced by `open-run.sh` (exit 2) on Claude
  Code; OpenCode has no such mode, and its prompt says so.
- The installer edits **only** its own `hooks` entries in `settings.json`, after a backup and
  with validation; user settings and user hooks are never altered. `uninstall.sh` unregisters
  them again and never deletes `runs.jsonl` or any `PROJECT.md`.
- Empty tool output is never treated as a confirmed negative (second independent method required).

## Debt and known risks

- **Check any figure this harness reports about itself.** All four it has ever reported were wrong
  at least once, and a human refusing a number that felt wrong found every one — no test did. Cost
  is now `cost_usd`: model-aware, Critic included, `null` rather than partial when a model is
  missing from `prices.conf`, with raw token components kept so a run can be repriced from the
  record. History and calibration: `docs/measurement-history.md`.
- **`SubagentStop` on Claude Code — confirmed live, not just documented.** Three of five real
  Claude Code runs in `runs.jsonl` carry non-empty `critic_findings` (`0/0/2/3`, `0/0/3/1`,
  `0/1/4/2` — 2026-09-07T03:25:41Z, 2026-09-11T15:44:51Z, 2026-09-11T16:04:28Z), which only
  `subagent-done.sh` writes, only on `SubagentStop`. That alone proves the event fires on this
  build. It also proves the payload's `session_id` names the PARENT run, not the Critic's own
  sub-agent session: `subagent-done.sh` calls `hk_guard` first, which requires an active run file
  under that exact id, and a sub-agent session — never opened via `/iamlazy` itself — has no run
  file of its own to match against. The two empty-findings runs (2026-09-12T00:27:39Z,
  2026-09-12T01:32:27Z) are `iamlazy-smoke` runs where the human declined the Critic; empty is the
  correct value there, not a gap. `Stop`'s `{"decision":"block","reason":…}` is separately confirmed
  on both hosts: the same 2026-09-11 `iamlazy-smoke` session (`7f32cddc`) hit the block, read the
  reason in its own transcript, and acted on it — reverted an out-of-scope file, re-invoked the
  Critic for real. Confirmed by contrast: `PreToolUse`'s `permissionDecisionReason` reaches the
  model too, which read a denial and adapted. Nothing about this channel is still unconfirmed on
  Claude Code; the breaker and scope gate still emit every documented channel at once (decision,
  `systemMessage`, stderr, exit 2) as defense in depth, not because any of them is in doubt.
- **Spawning the Critic asks, on Claude Code — now confirmed live.** A real run (2026-09-11,
  `iamlazy-smoke`, session `7f32cddc`) hit the native permission prompt with the hook's reason
  text rendered, the human declined it for real, and `critic_asked` recorded the attempt — so the
  close that followed cited an honest decline instead of a fabricated one. The earlier gap this
  closed: the same run's model first tried to fake the decline through `AskUserQuestion`, a tool
  `guard-agent.sh` never sees, and got blocked until it went through the real tool. On OpenCode the
  same hook output degrades to an allow — its adapter only recognises `deny`, so the Critic still
  always runs there, unchanged.
- **The breaker's floors carry more weight than its ratio**, and $0.08/line rests on four runs from
  two projects. If it fires on a run that was fine, the threshold is wrong, not the run. Its three
  numbers default in `flush-run.sh` and are overridable in `~/.iamlazy/config`, so recalibrating is
  an edit rather than a reinstall; whatever was in effect is logged with the run.
- **`gate_verdict` stays underived** — it would come from `ExitPlanMode`, whose payload shape is
  unconfirmed. `runs.jsonl` carries several schema generations; `/iamlazy-review` reports what each
  line has and never infers across them.
- **Hooks can be switched off.** `disableAllHooks` exists. Layer 0 is proof against forgetting,
  not proof against a decision.
- **The Critic's Bash guard reads the command string, not the process.** It stops the shell from
  writing; it does not stop a program the Critic legitimately runs — `npm test` may create
  fixtures, and that is intended. The discipline hole is closed, the hermetic seal is not.
- **A real end-to-end OpenCode run (2026-09-11, `opencode run`, disposable repo) confirmed one
  question and raised a more serious one.** `command.execute.before` does fire for `/iamlazy`:
  `open-run.sh` ran, logged `stage_reached:"ANALYSIS"`. But between that turn and the human's
  reply approving the contract, the CLI's one-shot process exit fired `session.deleted` —
  `end-run.sh` flushed the run as `abandoned` before a human ever answered. The reply that
  followed (`--continue`, in a NEW process) wrote the contract, edited both files, ran the tests,
  correctly spawned `iamlazy-critic` as a real sub-agent (right model, right session, its own
  re-verification) and closed — all of it true on its own merits, and **all of it with zero Layer
  0 tracking active**: no run file existed, so the scope gate, the Critic guard and the close
  signal were never consulted. Had the diff strayed out of scope, or the Critic call been faked,
  nothing would have caught it. This is unconfirmed for the interactive TUI (a long-lived process
  might never fire `session.deleted` between ordinary turns) — what is confirmed is that
  `opencode run`'s documented `--continue` workflow, which is exactly how a script or a second
  CLI invocation resumes a conversation, silently degrades every OpenCode guarantee back to prose
  the moment a human answer arrives in a separate process. See DELTAS Candidate 18.
  Still unconfirmed, for a different reason now (nothing ever got far enough to trigger either):
  whether a `throw` shows its reason to the model, and whether the gate's block fed back through
  `session.promptAsync` makes it continue. A Critic spawned in the **background** returns before
  it has reviewed; since 2026-09-16 `guard-agent.sh` refuses that spawn outright rather than
  relying on the prompt to ask for the foreground — see the V2 entry below.
- **A separate OpenCode V2 adapter exists at `adapters/opencode-v2/iamlazy.ts`**, targeting the
  native `@opencode/plugin` API (v2.0.x) rather than V1's `@opencode-ai/plugin`. Unlike V1's
  adapter, it has a real runtime dependency and must be bundled (`build.sh`, `bun build
  --target=bun`) before a V2 daemon can load it — a loose, unbundled file fails with `Cannot find
  package '@opencode/plugin'` even with the package correctly installed nearby, because the
  compiled daemon does not perform normal module resolution for a dynamically-loaded local plugin.
  Built, mutation-tested, and validated live end-to-end (contract → edits → a real two-cycle
  Critic review → automatic close) against a real v2.0.1 daemon; see its own `README.md` and
  `docs/decisions-2026-09.md`. `install.sh --tool=opencode-v2` installs it (builds from a real
  checkout, refuses cleanly under `curl|bash` or without `bun`); `--check` and `uninstall.sh`
  know its shape too. It is never auto-selected -- `--tool=opencode` still means V1, and `auto`
  never picks V2 -- which is what keeps this the same "candidate, not committed" status as
  Candidate 18 above, deliberately, rather than a side effect of wiring it in. Its
  `@opencode/plugin` dependency (build-time only, never at runtime) is a second declared exception
  to the "zero external deps" rule below, on top of V1's type-only one. `test.sh` now covers the
  installer's V2 path (a real install + build, byte-for-byte switching between V1/V2 leaves no
  stale shape, `--check`/`uninstall.sh` on it), the purity/hook-existence invariants (both
  adapters, plus an explicit V1/V2 hook-set-equality check), and the adapter's own 14-test
  `bun test` suite -- all mutation-verified. Since the installer's own V2 coverage already pays
  the one real `bun install` a fresh checkout needs, running the adapter's suite right after it
  costs nothing further; bun missing fails loudly on both, same standard as V1's adapter test.
  Four further gaps closed 2026-09-16 (audit → `adapters/opencode-v2/README.md`): `patch` edits are
  journaled per file (they matched no branch before, so a multi-file apply escaped the journal and
  the scope gate entirely); background sub-agents are refused by Layer 0 rather than silently
  closing a run as a declared deviation with a review still in flight; `session.idle` is accepted
  alongside `session.execution.*`, gated so one turn flushes exactly once; and the plugin's cleanup
  path is now exercised by a test that proves the subscription actually terminates. The `patch`
  branch is confirmed against the real daemon: a genuine multi-file apply (an add plus a
  move-with-edit) journaled all three paths, the move's SOURCE included — the one `applied[]` never
  reports. Note that `patch` registers with `codemode: false`, which keeps it out of the Code Mode
  catalog a model reaches through the `execute` sandbox, so most sessions cannot call it at all and
  report it as nonexistent. A plugin can expose it by flipping that option; **this adapter
  deliberately does not** — translating events is its job, choosing which tools the host offers a
  model is not.
- **`curl | bash` requires `IAMLAZY_RAW_BASE`**; offline is clone+run.

Why the design is what it is: `docs/decisions-2026-09.md` (the unchecked suppositions, the gate's
timing, `base_ref`, TypeScript as a translator), `docs/decisions-2026-08.md` (Layer 0's rollout),
`docs/measurement-history.md` (every number that was wrong, and the breaker's calibration).
