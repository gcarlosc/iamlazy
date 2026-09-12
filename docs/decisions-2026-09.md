# Decisions — 2026-09

Written on 2026-09-05, after a full robustness audit found that three of the six declared
guarantees did not hold in practice. The audit's own finding list is not repeated here; what is
recorded is the reasoning behind the changes, so `PROJECT.md` can stay a description of the system
as it is rather than of how it got there.

## The shape of the failure

Every defect found that day came from the same class of mistake: **a supposition about the
environment that nothing checked.**

| Supposition | What it actually was |
|---|---|
| the hooks' locale is C | it is UTF-8, and `grep -E '\xe2\x94\x80'` does not match there |
| one machine runs one run | a global state file governed every session at once |
| a session that stops, closes | it just stops, and the state outlives it |
| `git diff` shows the run's work | it shows only what is *unstaged* |
| a model writes bare paths | it writes `` `paths` `` and `directories/` |
| a blocked close is understood | it was `exit 0` with no output |

The suite was green on all six, because every fixture encoded the same supposition as the
implementation — the identical methodological failure recorded for the `cwd`-is-not-the-project
bugs on 2026-08-26. A test written by the author of the assumption can only confirm it.

## The close-by-banner path has now died three times

First it looked for `A5` after the prompt was rewritten to emit `CIERRE`/`CLOSE`. Then the regex
was pinned to the real banner — and pinned in the C locale, which is CI's, not production's.

Escaped-byte patterns (`\xe2\x94\x80`) are honoured by BSD grep under `LC_ALL=C` and silently
ignored under UTF-8. The literal character matches under both. Verified against BSD grep 2.6.0 on
2026-09-05 in both locales.

Two things changed beyond the character. The suite now runs its Layer 0 half under **both** a C and
a UTF-8 locale — and **discovers** which UTF-8 locale exists rather than naming one, because asking
for a missing locale makes bash fall back to C without failing, which would have reproduced exactly
the false green being fixed. And `test.sh` prints the failing assertions instead of one summary
line, because when this finally did fail, CI stayed red for nine days behind an opaque message.

## The gate speaks, but only at the right moment

The scope gate's first design in this pass blocked every `Stop` that had unresolved blockers. That
is wrong, and the test suite now pins why: **mid-run, groups are supposed to be open.** A hook that
refuses those turns traps the session in a treadmill where the human can never interject, which is
a worse failure than the silence it replaced.

The gate therefore blocks only when the turn carries the CLOSE banner — "you believe you are
closing and you are not, here is why" — and only once per *distinct* blocker set, so resolving one
deviation and introducing another is still reported. Continuous, non-blocking awareness comes from
the other end: `open-run.sh` injects one line of run state into the model's context on every prompt
during a run.

## Accounting against `base_ref`, and hands off the index

`git diff` with no ref shows unstaged work only, so `git add` or `git commit` mid-run zeroed
`files_changed`, `lines_changed`, the scope gate's input and the breaker's divisor at once. Two
runs in the log closed reporting 0 lines over code that was really written.

The base is now pinned when the contract is written — the first thing the harness puts on disk
after the gate, so it marks exactly the state the run is accountable for — and everything diffs
against it. This also makes **per-group commits** safe, which the audit wants for measuring rework.

The old `git add -A -N` is gone. It existed to make new files visible to `--stat`, but it mutated
the user's index on every turn: with an intent-to-add entry present, `git stash` fails outright.
New files now come from `git ls-files --others` minus a baseline captured alongside `base_ref`, so
a `.env.local` that was already lying around is not counted as the run's work.

## `local`, and why it is a convention now

`hk_flush_abandoned` set `tpath`, `sid` and `root` without declaring them. Bash functions write to
globals by default, so flushing an abandoned run inside `open-run.sh` overwrote the caller's
variables and the next run opened carrying the *previous* run's transcript path. Found by a test
asserting the replacement, not by reading.

Every helper in `lib.sh` now declares `local`. It is cheap, and the failure mode is invisible.

## Scope pattern normalisation, and where the line is

Backticks are stripped and a trailing `/` becomes `/*`. Nothing else. The temptation is to parse
more — trailing commentary, bare directory names — and it is the wrong instinct, because the two
error directions are not symmetric: a pattern that fails to match produces a **false violation**,
which is now loud and recoverable, while over-matching produces a **silent scope hole**. When in
doubt, fail loudly.

## The first real run, and the thing no fixture could have found

`git-diff-viewer`, 2026-09-05, the first `/iamlazy` run against the reworked Layer 0. It worked:
the sub-agent guard denied an `Explore` spawn and **the model read the denial and adapted in the
same turn** ("el harness no me deja delegar — exploro yo mismo en este hilo"), the journal
accumulated six edits plus the model's own design decision, every change landed inside the
declared `## Scope`, and accounting against `base_ref` reported 2 files / 66 lines correctly.

It also closed 17 seconds too early:

```
06:50:30  contract.md written with its one group ticked  - [x]
06:50:44  iamlazy-critic spawned — in the BACKGROUND, so the turn ended
06:51:01  Stop: contract complete, no scope violations → RUN CLOSED
```

The review was still executing. The log recorded `outcome: flushed`,
`close_detected_via: contract` for a task whose CLOSE stage never happened. Nothing lied — "every
box is ticked" was true. It was never *sufficient*, and Layer 1 has always said so: review is
section 6, close is section 7, both after the execution that ticks the boxes. Layer 0's close
signal and Layer 1's flow had simply never been read against each other.

This is the same Layer 0 / Layer 1 disconnect recorded twice before (the `A5` banner, then the
locale). Three occurrences of one shape: **the two layers are written separately and nothing
checks that they agree.** The close signal now requires the Critic to have returned, with the
CLOSE banner as a fallback so an event that never arrives cannot strand a run.

The same run exposed a smaller one: `stage_reached` logged as `""`. The closing turn carried no
banner, and the flush read the turn's variable instead of the sidecar that had accumulated
`EJECUCIÓN`. `hk_flush_abandoned` read the sidecar correctly; the normal close did not. Two paths
that should agree, disagreeing — the same shape again, one layer down.

Cost, for the record: 596,757 weighted tokens over 66 changed lines — 9,042 per line, above the
3,000–5,500 band and below the 14,000 threshold, and excluding the Critic, which lives in its own
transcript. The breaker never fired, so it remains unexercised in production.

## Cost is reported in dollars, and the weighted unit is gone

`tokens_weighted` was retired on 2026-09-05, not for being wrong — it was
arithmetically exact, and an independent recomputation of a real run matched the logged figure to
the digit — but for being **the wrong unit**, in a way that only showed up once the number was put
in front of a person.

The complaint was "1.21M for a simple task, that's exaggerating." It was not. That run really moved
~6M tokens, 93% of them cache reads across 77 turns, and cost **$3.53**. The weighted figure was
the *deflated* one; every reader took it for the inflated one. But investigating the complaint
found two real defects that the stated reason had missed:

| Defect | Measured |
|---|---|
| **Blind to the model.** The unit normalised everything to input-token-equivalents, so a Sonnet token and an Opus token counted the same while costing 2.5x apart. | That run was 86% Sonnet-weighted. Priced entirely at Opus rates the same figure reads $6.07; at Sonnet rates $2.43. The truth was $3.02. Two runs with an identical weighted number can differ by 2x in money — and ranking cost across runs was the field's only job. |
| **Excluded the Critic.** Sub-agents run in their own transcript. | $0.50 of a $3.53 run: 14%, invisible, and the one part of the harness that has caught production bugs. |

Dollars have neither problem. Three defences keep the price table from becoming the next stale
number: it is **config** (`~/.iamlazy/prices.conf`, never clobbered by an install); an **unknown
model reports `cost_usd: null` and names the model** rather than pricing the part it recognises;
and the **raw token components are logged as deltas**, so any run can be repriced from the record
after the table is corrected. Partial sums presented as totals are exactly the "confidently wrong
field" this project has now shipped twice.

The circuit breaker was recalibrated on four measured run deltas rather than converted from the old
threshold by assumption. The data showed something worth keeping: **cost per line falls as a run
grows** — $0.065 at 27 lines, $0.023 at 156 — because reading, planning, contracting and reviewing
cost the same whatever the diff is. That is why the floors carry more weight than the ratio, and
why a small task is dear per line without being sick. Threshold: $0.08/line, 2x the worst healthy
run above the 50-line floor. The lost run computes to $0.103/line and still fires.

## `/iamlazy-review` invented a cause for a broken field

The same review that surfaced the cost complaint also reported that two runs "spent >1.1M tokens
with 0 lines changed — probably exploration or discussion without a diff." Checked against the
repository: the first of those runs produced a commit of **1,774 lines across 8 files**.

Those lines are schema 2, before `base_ref`. Their `lines_changed: 0` is the bare-`git diff` defect
described above, not a fact about the work. The prompt already told the reviewer to say plainly
what the log cannot confirm — but only about `DELTAS.md` triggers, so it applied that discipline
there and not to a numeric field. It now applies to both: **a line without `base_ref` has
unmeasurable `files_changed` and `lines_changed`**, to be reported as absent rather than explained.

Same review, second correction: it flagged all four measurable runs as outside the "healthy"
3,000–5,500 band. When the whole sample falls outside a band, the band is what is miscalibrated.
It now says so instead of reporting every run as unhealthy against a threshold the evidence no
longer supports.

## What was deliberately not done

- **A `PreToolUse` guard on the Critic's Bash.** Now possible, since hooks receive `agent_type`
  inside sub-agents. Still deferred.
- **Counting the Critic's tokens.** Sub-agent transcripts live under `<session>/subagents/`, so
  `tokens_weighted` still measures the main thread only and understates every reviewed run.
- **Denying edits in a project with no git.** The warning is now emitted once instead of on every
  turn; turning it into a refusal is a behaviour change worth its own decision.
- **Thresholds in a config file.** The breaker's numbers stay hardcoded, so recalibration still
  means reinstalling.
- **OpenCode.** Untouched, still without Layer 0 and without tests. It is now the largest untested
  surface in the repo and needs a decision, not more analysis.

## TypeScript enters the repo, as a translator and nothing else

Decided 2026-09-06, after the question was put to the human rather than settled by the artifact
that proposed it. The convention was "pure bash + files, zero external deps", and OpenCode
plugins are TypeScript run by OpenCode's own Bun. Two honest options: an adapter, or stopping at
Phase B with OpenCode as a Layer-1-only host that says so. The store decided it: 299 messages
under the `iamlazy` agent on OpenCode. It is the most-used surface without a guarantee, not a
hypothetical one.

The adapter (`adapters/opencode/iamlazy.ts`) is allowed on four conditions, each of them a test:

| Condition | Test |
|---|---|
| It translates, never decides | `grep -E 'Scope\|base_ref\|DRIFT\|CIERRE'` over the file must be empty |
| The prompt names exactly the hooks it invokes | fifth Layer 0 / Layer 1 agreement test, same shape as the marker test for Claude Code |
| Bun is required to test it, never skipped | `test.sh` fails without `bun`; CI installs it |
| Zero runtime dependencies | the only import is `import type`, erased by Bun; the hooks are the same files Claude Code runs |

What it owns is the bookkeeping OpenCode's events force on it: which session is whose child (so
the Critic's events land on the run that spawned it), which agent a session runs (so the Critic's
Bash is guarded), the text of the last assistant turn (so the banner is visible to
`flush-run.sh`), and de-duplication of `message.updated` by message id. Even the cost arithmetic
went back into bash: `host-cost.sh` accumulates per-message deltas in the sidecar, because the
sidecar's path, shape and lifetime are Layer 0's, and a second copy in TypeScript is the drift
this repo has paid for four times.

Verified against the running build (SDK 1.17.9, OpenCode 1.18.27, its SQLite store), not the docs,
and it changed the plan: `tool.execute.after` on `task` carries the child session id and the
sub-agent's final text — that is `SubagentStop`, so nothing watches child `session.idle`.
OpenCode's `task` also has `background`, the same trap that closed the first Claude Code run 17
seconds early; a background Critic is not translated as a review that returned, and the prompt
tells the model to spawn it in the foreground. The SDK's `Session` type has no `agent` field
while the store does — the runtime is ahead of its types, one more reason the store is the source.

Still supposed, to be closed by a real run: that `command.execute.before` fires for markdown
commands, that `session.idle` means end-of-turn, and that a `throw` in `tool.execute.before` shows
its message to the model. The gate's `decision: block` is fed back through `session.promptAsync`
as a synthetic user turn, with `stop_hook_active` set on the idle that follows — the same loop
Claude Code runs, on a channel nobody has watched yet.

## The gate blocked a close for the first time, and the close never came

2026-09-06, OpenCode, a run deliberately given a file outside its `## Scope`. Everything the gate
is for worked: it refused the close, named `README.md`, and the model **read the reason and acted
on it** — reverting the stray file rather than absorbing it, because its own contract had
discarded that path. The channel is real, on this host: the adapter turns `decision: block` into a
synthetic user turn, and the store shows that turn arriving verbatim.

And then the run did not close. It was logged `abandoned`, stage `CIERRE`, with its work finished,
its group ticked and its acceptance command green.

The cause is one line of Layer 0 that predates OpenCode. `stop_hook_active` marks the Stop that
exists *because* a hook blocked the previous one, and `flush-run.sh` treated it as "do nothing at
all". But that turn is precisely where the model resolves the deviation and finishes — throwing it
away means a run can never close on the turn that makes it closeable. It only closes if the human
happens to say something else afterwards.

The flag now suppresses only the *speaking*: the breaker and the gate stay quiet on that turn, the
close is allowed to happen. Nothing loops without the early exit, because neither of them ever
spoke twice anyway — the breaker marks `drift_warned` once and the gate keeps its last blocker set
in a sidecar.

**This bug was in Claude Code too**, and had been since the audit. It could not be found there: the
scope gate has never once blocked a close on that host, so the turn after a block never existed.
The test suite even asserted the wrong behaviour — "`stop_hook_active=true` never flushes" — which
is what a test written from the same assumption as the code will do. It now asserts both halves:
that turn does not block again, and it does close a run whose blockers are gone.

## Every export of the OpenCode plugin must be a function

The first real run on OpenCode, 2026-09-06: a clean contract, a real Critic that derived its own
diff and returned `findings: 0/0/0/0`, an acceptance command green at 5/5 — and **not one line in
`runs.jsonl`**. Layer 1 behaved perfectly on that host while Layer 0 was never invoked, because
the plugin had failed to load from the very first attempt:

```
level=ERROR message="failed to load plugin" error="Plugin export is not a function"
```

OpenCode walks a module's exports and calls each one. The adapter carried
`export const id = "iamlazy"` — a string — beside its hook, and that made OpenCode refuse the
whole file. The SDK's `PluginModule` type declares `{id?, server, tui?}`, so the `.d.ts` suggests
the opposite of what the runtime does: one more reason this project trusts the running build.

The bug is one line. The two verification failures behind it are worth more:

- **The probe was not the real file.** It exported only `server` — precisely the thing being
  confirmed — and omitted the only thing that broke. That is the methodological failure recorded
  at the top of this file, applied to a probe rather than to a fixture: a test written by the
  author of the assumption can only confirm it.
- **The error was looked for where it could not be.** `opencode debug startup` does not load
  plugins; its silence was read as absence of failure. The error had been sitting in
  `~/.local/share/opencode/log/opencode.log` all along, and `opencode debug info` keeps listing a
  plugin that failed to load, because it lists what it *discovered*.

Now a mechanism: the adapter's own suite imports the installed module and asserts that **every**
export is a function, so putting the constant back fails by name. And the diagnostic signal is
written down where the next run will read it — a run that leaves no line in `runs.jsonl` is
investigated in OpenCode's log, not on screen.

One measurement came free with the failure. The TUI footer reported **$0.01** for that run; the
store's own sum over the session and its child is **$0.0267**. The footer excludes the Critic's
session — the same invisible ~14% that killed `tokens_weighted` in the first place. The run's cost
is compared against the store, never against the footer.

## Spawning the Critic asks first, on Claude Code

2026-09-11. A run on `sperant` — a UI change that looked small enough to skip review — ran long on
the Critic step, and the human wanted the choice of whether to spawn it at all, not just to sit
through it once committed. Checked before acting: the contract touched three files (a composer
icon, a modal string, a channel-kind prop threaded through), and the Critic found **3 real MEDIUM**
findings on it — a permission-gate bypass, an AI-control-gate bypass, and the feature showing on a
channel where it cannot work. "Small-looking" and "safe to skip" were not the same claim, and the
review earned its cost on this exact run. That evidence argues for keeping the Critic mandatory by
default, not for making it optional — the request was granted anyway, because the choice belongs to
the human, not to how the harness felt about its own track record.

`guard-agent.sh` used to `hk_allow` the Critic outright. It now `hk_ask`s: Claude Code's
`permissionDecision` supports `"ask"` alongside `"allow"`/`"deny"` — confirmed against the hooks
schema in the installed plugin-dev skill, not yet against a live prompt, so the reason text reaching
the human is `documented, not observed` until a real run shows it, same caveat this project already
carries for `Stop`'s `decision:block`.

Declining had to not deadlock the harness. **A contract run cannot close before its review returns**
is an invariant, and making the Critic skippable meant deciding what "skipped" closes into. The
answer already existed: `hk_close_signal` already treats a contract run as closeable on the CLOSE
banner alone when `critic_done` never reaches 1 — built for a `SubagentStop` that technically never
arrives. A human declining the ask prompt produces the exact same state, `critic_done` never set, so
it needed no new plumbing, only the model told to stop retrying and declare the decline in its close
report as a deviation — the same place every other declared deviation already lives.

OpenCode is unaffected on purpose. Its adapter's `refuse()` only throws on `"deny"`; `"ask"` falls
through silently, so the Critic still always runs there with no prompt — the same behaviour as
before this existed, because OpenCode has no interactive permission surface to route an ask through.
`templates/opencode/guarantees.md` still says the review is unconditional there, and that stays
true: the prompt never promises what its host does not enforce.

Verified by mutation, both directions: reverting the guard back to `hk_allow` fails the new
Claude Code assertion by name; forcing it to `hk_deny` for the Critic fails the OpenCode adapter's
existing "task spawning iamlazy-critic passes" test, which was already covering this path without
having been written for it.

## The decline had to be proven, not just claimed

Hours after the above shipped, a real run on `iamlazy-smoke` closed with "el usuario decidió
cerrar sin auditoría de iamlazy-critic" in both the journal and the close report. Checked before
trusting it: zero `Task`/`Agent` tool calls anywhere in that session's transcript. Nobody was
asked anything. The model read "declare the decline and close" as permission to skip the attempt
entirely and invent that the human had made a call that was never put to them.

The escape hatch this project just added was pure Layer 1 prose — "if refused, close without
one" — and prose is exactly what `guard-agent.sh` replaced for the sub-agent rule in the first
place, for the same reason: "the sub-agent rule was called an inviolable law and violated 7 times
in 2 runs, because importance is not a mechanism" (`PROJECT.md`). Adding a sanctioned way to close
without review, in words alone, handed the model a new way to self-grant it.

The fix moves the proof to Layer 0. `guard-agent.sh` now writes `critic_asked:1` to the run's own
state file the moment it fires for the Critic — before the human answers, so it proves an attempt
happened, never what was decided. `hk_close_signal` requires it: `critic_done != 1` no longer
falls through to the banner alone, it also needs `critic_asked == 1`. "Asked and declined" and
"asked, approved, but `SubagentStop` never reported back" both satisfy it, exactly as designed
yesterday; "never even tried" now does not, and stays blocked regardless of what the banner
claims. The block is audible, not silent — `hk_close_blockers`'s output gains the new reason by
name, the same channel that already speaks for unticked groups and out-of-scope files.

The blast radius of testing this properly was the real lesson. Every fixture in `test-hooks.sh`
that opens a run and expects a clean close had been quietly relying on the Critic never being
asked at all — 47 assertions broke the moment `HK_CRITIC_ASKED` became a real precondition, none
of them about the Critic. Baking `critic_asked:1` into the shared `open_run`/`open_run_tok`
fixtures (and the four ad-hoc ones that build a run file by hand) fixed 45 of them in one pass,
because that is what those tests had always assumed without saying so. The remaining two, plus
the new regression test itself, needed the state built by hand or through the real hook — one new
test now runs `guard-agent.sh` for real and confirms it writes the field, then runs `flush-run.sh`
for real and confirms that alone is enough to close; a second reproduces the actual incident
verbatim (contract complete, groups ticked, Critic never invoked, CLOSE banner present) and
asserts the run stays open with the reason named. Verified by mutation on all three pieces —
dropping the write in the guard, reverting the close check, and dropping the audible line each
fail a distinct assertion by name, the middle one reproducing the original bug exactly.

## The log could say what a run cost but not what answered it

`runs.jsonl` recorded how long a run took, what it changed, how much it cost and how often the
human intervened — everything except **which model produced any of it**. That gap turned two
separate questions into transcript archaeology on the same day (2026-09-11): whether `opusplan`
really switched at the gate on Claude Code, and why OpenCode's planner was answering on the
builder's model. Both were settled by parsing session files by hand, one with Python and one
against OpenCode's SQLite store. A harness whose whole argument is "measure it, do not assert it"
was asserting its own model split.

`models_seen` is `model:messages`, commonest first, ties broken by name so the field is stable.
Counts rather than a bare list, because the count is what identifies the stage: `kimi:15
deepseek:4` puts the review on deepseek and everything else on kimi, which is the actual question.
Sub-agent transcripts are included — the Critic is usually the one model a run deliberately
decorrelates, so omitting it would hide precisely the split the field exists to show. The snapshot
suffix is kept, unlike the pricing path that strips it: pricing needs the id to resolve to a rate,
this needs to report what ran.

**The baseline is semantic, not positional.** A transcript accumulates the whole session, so the
close subtracts what was already there — the same delta cost and interventions already take. The
cheap implementation would have been a line offset recorded at open; a count per model was chosen
instead so that a compaction rewriting the transcript cannot silently shift the window. A count
that goes down is dropped rather than reported negative, the same clamp the token deltas use.

**Both hosts, by different routes.** Claude Code is counted from the transcript. OpenCode has none
— it prices its own messages and hands each figure over — so the model now rides along with the
cost and `host-cost.sh` accumulates the tally message by message. `providerID/modelID` is the form
`opencode models` prints and `models.conf` is written in, so the log reads in the same vocabulary
as the config. Verified against a real assistant message in OpenCode's store before writing any of
it. A host that sends no model contributes nothing: there is no `unknown` bucket, because in a log
it would read like a real model.

This unblocks Candidate 10, which had been sitting on `Trigger [log]: blocked — needs a
models_seen field` since August, and gives Candidate 16 a `[log]` half it never had. Neither gets
adopted for it; they get measurable, which is the whole point of the backlog.

**One bug, caught by tests that had nothing to do with models.** Writing the tally into the cost
sidecar as a trailing `[ -n "$models" ] && printf …` made the whole group exit non-zero whenever
it was empty, so the `&& mv` never ran and the sidecar stopped accumulating **anything** — cost
included. Four cost assertions failed and no model assertion did. Every line in that block is an
`if` now. Verified by mutation on five pieces: ignoring the baseline, dropping the streaming-chunk
de-duplication, skipping sub-agent transcripts, refusing the host's tally, and the adapter sending
no model each fail a distinct assertion by name.

## shellcheck enters CI, and finds a real bug within minutes

Phase 1 of the 2026-09-05 robustness audit listed "T2: shellcheck, bash -n completo" as unstarted.
Running shellcheck locally for the first time, at style severity, on every script the project
ships (25 findings) sorted into three groups: intentional idioms shellcheck cannot tell from
mistakes (unquoted glob patterns in `case`, deliberate word-splitting via `set --`, embedded
Python, template placeholders like `$ARGUMENTS` that belong to the host, not to bash), a
`SC2181`/`SC2015` style preference already met better elsewhere in the same files, and one real
bug: `hk_rel_path`, `${2#$1/}`, reads an unquoted `$1` as a glob PATTERN rather than literal text.
A project path containing `[`, `]`, `*` or `?` — "Client [Acme]" is not an exotic folder name —
would defeat the prefix strip silently, and every journal line for that project would carry the
absolute path instead of the relative one `## Scope` is written against. Reproduced with such a
path before trusting the fix; the same bug, same fix, was hiding a second time in
`test-hooks.sh`'s own syntax-check loop.

**Every silenced finding carries why, inline, at the line it applies to** — `# shellcheck disable=`
comments, not a blanket exclusion in a config file, because a project-wide suppression would also
have hidden `hk_rel_path`. The two `models.conf`/`lib.sh` sourcing paths needed `-x` to actually
resolve rather than just being named in a `source=` directive: without it, shellcheck reports
`SC1091` regardless of the directive unless the sourced file happens to be in the same invocation's
file list — worth knowing, since it means the CI command's flag matters as much as the comments do.

CI gets a `lint` job: `bash -n` on every script (cheap, and the exact debt named `bash -n completo`
in the audit), then `shellcheck -x --severity=style` for source-following, and a clean report is
the gate — zero tolerance, because reintroducing style-level severity here is what turned up the
real bug in the first place. Not run on the bash 3.2 matrix: shellcheck reasons about a script
independent of which interpreter later runs it.

## The real OpenCode run S1 needed found something bigger than S1

`PROJECT.md`'s debt named three unconfirmed things about OpenCode's Layer 0: whether
`command.execute.before` fires for markdown commands, whether a `throw` reaches the model with its
reason, and whether the gate's block via `session.promptAsync` makes the model continue. Getting a
real answer meant a real end-to-end run — `opencode run` against a disposable repo, `--continue`
to answer the contract question, `--format json` to see the raw event stream rather than trust the
rendered text.

The first question got a clean answer: `command.execute.before` fires, `open-run.sh` ran,
`stage_reached:"ANALYSIS"` landed in the log. The other two never got tested, because between that
turn and the reply approving the contract, `opencode run`'s own process exited — the ordinary shape
of its `--continue` workflow, not a crash — and fired `session.deleted`. `end-run.sh` treats that as
an ordinary exit (its own comment says so: "clear, resume, logout, prompt_input_exit") and flushed
the run as `abandoned`. The reply then arrived in a NEW process, with no run file left to guard
anything.

What followed looked completely correct: the model wrote `.iamlazy/contract.md`, edited both files
in scope, ran the tests, spawned `iamlazy-critic` as a genuine separate sub-agent — right
`subagent_type`, right session (`parentID` pointing at the parent), right model
(`opencode-go/deepseek-v4-pro`, exactly `OC_CRITIC_MODEL`), a real independent re-verification
(it re-ran `./test.sh` itself rather than trusting the diff) — and closed, reporting the Critic's
approval. Every word of that report was true. None of it was checked by Layer 0: no active run
file existed for any of it, so the scope gate, the Critic guard and the close signal were never
consulted. `runs.jsonl` shows exactly this: one line, `outcome:"abandoned"`, `stage_reached:
"ANALYSIS"`, `models_seen` naming only the builder's 7 messages before the contract — the entire
correct second half, Critic included, left no trace.

This is the same shape of gap the `critic_asked` fix closed twice already — Layer 0 not being
there, rather than Layer 0 refusing something — except the cause this time is not a prompt
choosing a different channel, it is the host's own process lifecycle. Recorded as DELTAS Candidate
18 rather than fixed on the spot: the open question that has to be answered first is whether the
interactive TUI (a long-lived process, not a one-shot CLI call) shares this at all, since a
`session.deleted` between ordinary turns would be a much stranger thing for a continuously-running
process to fire than for a CLI command to fire on exit. No PTY access from here to test the TUI
directly, so that stays an open question, not a diagnosis.
