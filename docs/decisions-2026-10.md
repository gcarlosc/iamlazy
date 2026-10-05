# Decisions — 2026-10

Written on 2026-10-02, during Phase 0 of the production-readiness plan: the changes that had to
land before anyone other than the author installs the harness. As in the September log, the
findings are not repeated here; what is recorded is why each change has the shape it has.

## The installed hooks were two weeks behind the repo

`install.sh --check` on the author's machine failed on four hooks per host. The stamp read
`48523f5`, from 2026-09-16; the breaker's absolute ceilings and schema 9 landed on 2026-09-18. So
the duration and dollar ceilings had never run in production anywhere, the author's machine
included. Reinstalled; `--check` now passes.

Reinstalling exposed a second defect. The stamp is `git rev-parse --short HEAD`, and the author
installs from a working tree. An install with uncommitted enforcement code would have stamped a
SHA it was not running, which defeats the stamp's only purpose: "was this run before or after the
fix". It now reads `<sha>-dirty` when `hooks/` or `adapters/` differ from HEAD. Other files do not
count: the stamp names enforcement code, not prompts or prices.

## `cost_usd` was wrong in four independent ways

Found by reading the provider's price reference against `prices.conf`, then measuring two real
Claude Code transcripts (this repo's own session and the 6386-second sperant run):

- **Cache writes.** Priced at 1.25x input, the 5-minute TTL. Every write in both transcripts was
  a 1-hour write, which costs 2x. The usage block says so per message in
  `ephemeral_1h_input_tokens`; the remainder of `cache_creation_input_tokens` is priced at 1.25x,
  which keeps every older fixture and transcript priced exactly as before.
- **Cache reads.** Priced at 0.1x input for every model. Opus 5.5 reads at 0.05x and Fable 5.1 /
  Mythos 5.1 at 0.025x. Reads are most of a run's tokens, so this was the largest error of the
  three on those models. `prices.conf` gains an optional fourth column for the read price; absent
  means 0.1x, which is what every older model charges. A column instead of a per-model constant in
  the code, because prices are config and the human edits them without reinstalling.
- **Null with nothing named.** A background agent's completion notice carries its own
  `"usage":{...}` with no model and no token field; Claude Code's `<synthetic>` messages carry a
  usage block of zeros. The scan read both as "a model with no price", so one such line in a
  session made the whole run `null`. For the first shape `cost_unpriced` stayed empty too, which
  is the unexplained null this project already fixed once. One rule covers both: a usage block
  whose token fields add up to zero consumed nothing and is never looked up. A narrower rule
  ("must carry output_tokens") was written first and removed, because no observed line
  distinguishes it from the zero-sum rule and so no test could ever prove it.

The two scans that priced messages each carried their own copy of the arithmetic, with the wrong
constants in both. They now share one awk block, `HK_AWK_USAGE`, prepended to every program that
reads usage, so the model count and the unpriced listing agree with the price on what a message
is.

A fourth defect sat under all three, older than any of them. Every price loader keyed on awk's
`NR==FNR`, which is true for every line of the second file when the first one is empty. A missing
`prices.conf` (the scan substitutes `/dev/null`) or an empty one therefore fed the whole transcript
to the loader: cost 0, tokens 0, no models. The run would have been logged as free on exactly the
machine whose `--check` says every cost will be null. The loaders now key on `FILENAME == ARGV[1]`.

Measured effect on whole-session totals: the sperant session rises about 5%, and this repo's
session goes from `null` to a figure. Historical lines in `runs.jsonl` are not repriced: they keep
only the summed token components, not the per-model or per-TTL split a reprice would need.

The breaker's ratio threshold and the healthy range `/iamlazy-review` quotes ($0.023 to $0.065 per
line) were both computed with the old formula. A shift of this size sits well inside the 2x margin
the ratio was set with, so neither moves now; both are recalibrated with the pilot's runs.

## Notices reach the human as one JSON object, on Claude Code

`flush-run.sh` printed each notice where it found it. The hooks reference parses stdout as a single
JSON value, so two notices on one Stop, or a notice followed by a block, produced output nobody
saw. Notices are now collected and printed once, at the exit-0 points only. One that a block
deferred is marked as said only when it is printed, so it appears on the next Stop instead of
being lost.

Two notices joined the existing "no git" one:

- **No price for a model.** Without a cost, the ratio and the dollar ceiling cannot fire; only the
  duration ceiling is left. That used to happen in silence, and it is the normal state the day a
  model ships. Said once, mid-run, while it can still be fixed.
- **`.iamlazy/` not in `.gitignore`.** The README promised this and nothing did it. Said at the
  close only, so it never interrupts a run. It goes to the human, not the model: a model that edits
  `.gitignore` itself would put a file outside `## Scope` and block its own close.

On OpenCode none of these notices reach anyone. Both adapters act on `flush-run.sh` only when it
exits 2, and drop its stdout otherwise, so the older "no git" notice never reached an OpenCode human
either. Carrying a `systemMessage` on exit 0 through both adapters is Phase 1 work; until then the
README states the notice for Claude Code only.

## A run file with no session id is cleared, not logged

Four `abandoned` lines in the author's log have an empty session id, cwd and duration. Nothing can
attribute them to a run. The invariant already says a payload without a session id triggers
nothing; a run file without one is the same input by another door, so the sweep now clears it
without writing a line.

## A contract written by any means gets a base (2026-10-03)

The first live run after Phase 0 (sperant, session `733298b9`) wrote its contract with
`cp plan.md .iamlazy/contract.md` from Bash. `track-edit.sh` only sees Edit and Write, so
`base_ref` was never pinned, and everything keyed on it went dark: the scope gate, the ratio
breaker, the close by contract, and the rule that a run cannot close before its review. The log
said 0 files and 0 lines over 3 files and 270 real ones, and the run closed on its banner.

Two changes, kept apart on purpose:

- **The snapshot moves to the open.** `open-run.sh` records HEAD as `open_ref` and the untracked
  baseline when `/iamlazy` starts, before any work. Taken when the contract appears instead, a file
  the run created before writing its contract would count as already there.
- **The contract is adopted, not just observed.** On every Stop and every prompt,
  `hk_adopt_contract` pins the base for a contract newer than the run's `<sid>.opened` marker,
  whoever wrote it. "Newer than the open" is what keeps the 2026-09-05 smoke-test bug fixed: a
  fully ticked contract left by the previous run is older, so it is never this run's contract.

Not covered: a contract written by Bash in a directory other than the session's. Nothing tells the
hooks where it is, so that run keeps the banner path, as before.

## The Critic's result is read from its own files (2026-10-03)

On Claude Code 2.1.287 the Critic runs in the background: its `meta.json` says
`"requestShape":"background"`, and the spawning tool returns `async_launched` at once. It returns
its report through a `SubagentHandback` tool call, so the tally travels inside that call. The last
assistant text, which is what `SubagentStop` carries, was "I'll start by reading the artifacts",
and the log recorded an empty tally over a real `0/1/3/5`. Whether `SubagentStop` fires at all for
a background agent is still unconfirmed; the transcript does not record hook events of that kind.

So the state is read from the files Claude Code writes for every sub-agent, and depends on no
payload: `hk_critic_pull` looks for an `iamlazy-critic` meta file newer than the run's open, and
for a `SubagentHandback` tool call in that Critic's transcript. Replayed on the real run's files,
it returns `critic_done` and `0/1/3/5`. `subagent-done.sh` stays, for builds where the Critic runs
in the foreground and its last text carries the tally.

The same files close the hole the run exposed: the spawning turn ended while the review was in
flight, and a CLOSE banner on that turn would have closed the run without it. `critic_asked` is set
when the spawn is asked about, so "declined" and "approved and still reviewing" looked identical. A
background Critic with no handback now blocks every close, and the gate says so. It stops counting
as running when the main transcript carries its task notification with a `<status>`, which means
it ended without a report, or when its files have not moved in 30 minutes. Without that limit a
crashed review would hold the run open until the 24-hour sweep.

One trap is pinned by a test. The Critic's own transcript lists its tools in a `prompt_snapshot`
line seconds after it starts, `SubagentHandback` among them. A grep for the bare tool name read
every Critic as finished three seconds in. The match is on the `tool_use` fragment.

## The human's decisions of 2026-10-03, and the rest of Phase 1

The review's open decisions were answered, all as recommended. What each one became:

- **No model is pinned by default.** `models.conf` ships empty. A command with no `model:` runs on
  the session model; the Claude Code Critic gets `model: inherit`, chosen over an omitted line
  because the sub-agent docs let `CLAUDE_CODE_SUBAGENT_MODEL` decide an omitted model and rank the
  frontmatter above it. On OpenCode an agent with no model uses the configured default, and a
  subagent the invoking agent's (opencode.ai/docs/agents). The README's claim that the variable
  silently overrides `CC_CRITIC_MODEL` contradicted those docs and was removed. `CC_CRITIC_EFFORT`
  joins it, empty by default: the docs define an `effort:` field for sub-agents, and the Critic's
  nine-minute review ran at the session's `xhigh`.
- **`CRITIC_ASK=0`** in `~/.iamlazy/config` skips the question before the Critic. The attempt is
  still recorded, so the close keeps its proof that a review was tried.
- **Two runs in one directory are announced, not separated.** The second `/iamlazy` names the
  other session in a `systemMessage`. Separating `.iamlazy/` per session would change paths the
  prompt and the Critic both know.
- **The previous contract and journal are archived** into `.iamlazy/history/<UTC time>/` when a
  run opens, never while another run is live there. Run 3 (session `966451fa`) is the argument:
  it wrote no contract, and the per-turn line called the previous run's contract "complete" while
  `task_summary` logged that run's task.
- **Native Windows is refused** by the installer, before anything is written, pointing to WSL.
- **The pilot** is three people and twenty runs, published below 15% abandoned. Nothing to build.

Phase 1, beyond the decisions:

- **The duration ceiling measures work, not the wall clock.** A turn that ends waiting for the
  human stamps `<sid>.laststop`; the next prompt adds the gap to `<sid>.idle`. A turn that ends
  with a background Critic still reviewing stamps nothing: that wait is the run working.
  `idle_seconds` is logged beside `duration_seconds` (schema 10), so a long run that did not fire is
  explainable from its own line.
- **A crashed hook exits 0 and leaves a line in `~/.iamlazy/hooks.log`**, which `--check` reports.
  The hooks are registered globally, and a crash surfaced as an error in unrelated sessions. The
  trap is installed by an explicit `hk_crash_guard` call in each hook, not on sourcing `lib.sh`:
  installed on sourcing, it turned the legitimate non-zero returns of single functions into 0 and
  20 tests went red. test.sh checks every hook calls it. The first version also read `$?` after a
  bare `local`, which always succeeds; the crash test caught it.
- **The Critic's Bash guard covers what the first version let through**: `find -delete`,
  `sort -o`, `rsync`, `install`, `patch`, `tar` that extracts or creates, `unzip` that extracts,
  and the git subcommands that rewrite the repository. Each read-only form is tested to still pass.
  `install` and `patch` match only in command position, because descriptions use both words.
- **A message is counted by its last transcript line, not its first.** The scans now share one
  record per message in `HK_AWK_USAGE`.
- **The per-turn status line says three things plainly**: no contract of this run yet; groups
  still open, which is the plan working; or files outside `## Scope`, the only state that says the
  run cannot close.
- **OpenCode V1 shows exit-0 notices as a toast**, never to the model. V2 has no channel to the
  human at all; its block path only reaches the daemon log, so its notices stay unseen there.

Deliberately not done: skipping the transcript scan once the breaker has fired. It saves about half
a second per turn, only in a run where the breaker already fired, which has never happened in
production, and it reorders the close path to get there.
