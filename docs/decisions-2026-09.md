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

## `task_summary` could split a UTF-8 character in half

Phase 1 of the audit named it (P2): `cut -c1-160` counts bytes under a byte locale, not
characters, so a multi-byte UTF-8 character sitting across the 160th byte gets cut in half.
Reproduced directly: 159 filler bytes, an `ó` straddling the boundary, `LC_ALL=C cut -c1-160`
left a lone `0xC3` with its continuation byte dropped -- an invalid byte sequence inside what
becomes a JSON string. Contracts are written in the human's language, and this project's own is
Spanish, so accented characters sit in `task_summary` on essentially every real run.

`hk_utf8_cut` (`hooks/lib.sh`) reuses the same UTF-8-locale search `test.sh` already runs for the
close-banner regex matrix: forcing one of `en_US.UTF-8` / `C.UTF-8` / `en_US.utf8` / `C.utf8` makes
`cut -c` count characters instead of bytes. When none exists on the system, the string is returned
unchanged rather than byte-truncated -- an oversized field is cosmetic, a split character is
invalid JSON, and this project's standing rule is that an imprecise value beats a confidently
wrong one. Verified against the reproduction under `LC_ALL=C` explicitly, the worst case; verified
by mutation that reverting to plain `cut -c1-160` fails exactly the new test and no other.

## `runs.jsonl` now knows what version of itself wrote each line

Phase 1 of the audit named it (I3): the log had no idea what version of the enforcement code
produced any given line, and the hooks copied to `~/.claude/iamlazy-hooks` (or OpenCode's
equivalent) could drift from the repo with nobody the wiser.

`--check` already solves the drift-detection half, and better than a version string could: it
compares the installed hooks against the repo byte-for-byte, so it can never be fooled by a
forgotten version bump. What it does not do is answer a question that came up twice tonight while
reviewing older runs by hand: was this one before or after a given fix landed. `hooks_version`
answers that — stamped once by `install.sh` into `~/.iamlazy/hooks_version`, read back by
`flush-run.sh` and `hk_flush_abandoned` at every close.

Prefer the git SHA when `$SRC/.git` is real (a clone+run install, which names an exact,
inspectable commit); fall back to a content fingerprint (`cksum` — POSIX, present everywhere this
project targets, unlike `shasum`/`sha1sum`'s macOS-vs-Linux naming split) of every file that
enforces something, hooks and the OpenCode adapter both, for a `curl|bash` install with no `.git`
to read a SHA from. Empty, never invented, on any install that predates this field.

`uninstall.sh` now removes the stamp alongside the `DELTAS.md` mirror — both generated by the
installer, not user data, and leaving the stamp behind would claim a version is installed after
the hooks it names are gone. Verified by mutation on both writers and the empty-field fallback;
schema bumped to 8.

## A V1→V2 OpenCode port had six regressions, and a seventh nothing could have mocked

A different agent ported the OpenCode adapter from the V1 `@opencode-ai/plugin` API to V2's native
`@opencode/plugin`. An independent read-only review (no source, config, or service changes) found
six actionable findings plus one blocking issue: the running v2.0.1 daemon reported the plugin as
`failed`, and `/iamlazy` was absent from `GET /api/command`.

**Root cause of the load failure, found by testing against the real daemon instead of trusting a
standalone `bun build`/`tsc` pass:** V1's adapter is `import type`-only, so it runs as a loose,
dependency-free `.ts` file that `install.sh` copies byte-for-byte. V2's API needs a real
`import { Plugin } from "@opencode/plugin"` at runtime, and the compiled daemon cannot resolve that
bare specifier when it dynamically loads a local plugin file or directory — confirmed directly
against the binary (`Cannot find package '@opencode/plugin'`), regardless of whether the config
entry pointed at a file or a directory, and regardless of the package being correctly installed in
an ancestor `node_modules`. The fix: `bun build --target=bun` the whole thing into one
self-contained `.js` file with zero imports left for the daemon to resolve, deployed as a loose
file (matching how OpenCode auto-discovers every `.ts`/`.js` file directly inside `plugins/`, the
same mechanism an unrelated pre-existing plugin already relied on).

A second, sharper lesson from the same investigation: the daemon caches a plugin's load-failure
state for the running process's lifetime. Editing the file, or calling the dedicated
`POST /api/plugin/await-activation` endpoint, does not re-evaluate it — only a restart does. Every
fix in this session had to be validated against either a disposable private server
(`opencode serve --port <N>`, no shared state) or, for the final live confirmation, an actual
restart of the shared background service.

**The six functional findings**, each confirmed live against a real, model-backed `/iamlazy` run
after the fix (not only against the review's mocks): the subagent guard read the wrong tool
name/field (`Subagent`/`input.agent` vs the `Agent`/`subagent_type` Layer 0 expects) and let every
sub-agent through unchecked; edit/write tracking read `filePath`/`file_path` while V2 sends `path`,
so no edit ever reached the journal; `session.usage.updated` supplies cumulative session totals,
and forwarding each one verbatim to `host-cost.sh` (whose contract is purely additive) summed $1
then $3 into $4; the Critic's completion hook required `input.subagent_type`, which V2 never sends,
so `critic_done` and the findings sidecar were silently never recorded; and the `/iamlazy` command
executor forwarded only `prompt.text`, dropping every file/agent/skill attachment.

**The seventh was not on that list, because nothing short of a live run could have found it.** The
adapter listened for `session.idle` and `session.status`, event names carried over from V1's
vocabulary. Neither exists on the real v2.0.1 event bus — confirmed by capturing its raw SSE stream
during an actual run, which only ever emitted `session.execution.{started,succeeded,failed,
interrupted}`. Every other fix could be (and was) verified with a mocked `ctx`; this one could not,
because a mock only ever fires the event names you hand it. Without it, a run opens, tracks edits,
and spawns and completes a real Critic review correctly, and then never closes: `flush-run.sh`
never once gets invoked, and the run sits in `~/.iamlazy/active` forever regardless of what the
model prints. Confirmed by hand-invoking `flush-run.sh` with the exact same payload the adapter
would have sent — it closed immediately and correctly — proving Layer 0's own logic was never the
problem.

**Final verification**, on the real shared daemon after a restart: a fresh `/iamlazy` run went
through contract → two real edits (journaled) → a real two-cycle Critic review (which itself found
and got a fix accepted for an unrelated pre-existing bug in the target repo's own test pattern) →
automatic close, with no manual intervention. `runs.jsonl`: `outcome:"flushed"`,
`critic_findings:"0/0/0/2"`, correct non-inflated cost, and `models_seen` correctly split between
the main model and the Critic's own model.

The fixed adapter now lives in this repo at `adapters/opencode-v2/iamlazy.ts`, with its own
`build.sh`, `bun test` suite (testing the built bundle, not the source — see its `README.md` for
why), and `package.json`/`bun.lock` pinning `@opencode/plugin@2.0.3`. Deliberately not wired into
`install.sh` or `test.sh`: OpenCode V2 support is still a candidate (see `PROJECT.md`'s debt
section and DELTAS.md Candidate 18, which is about V1's `opencode run` process lifecycle and is a
separate, still-open issue), not a committed host.

## One close, logged three times: closing a run needed a claim, not just a guard

The V2 adapter's live end-to-end run left a real artifact in `~/.iamlazy/runs.jsonl`: one session,
`outcome:"flushed"`, appearing three times, byte-identical (same `duration_seconds`, `cost_usd`,
`models_seen`). Not three runs — one run, logged three times.

`hk_guard` only checks that a run file EXISTS; it does not claim it. `flush-run.sh` (and
`hk_flush_abandoned`, which has the identical shape) both read the run file, do a page of
derivation, `hk_log_append` the line, and only THEN `hk_run_clear` it. Nothing stopped two
invocations from both passing the existence check, both computing the same close, and both
appending before either one cleared the file. V1 never hit this because one Stop meant one plugin
instance handling it. V2 does: the daemon instantiates the plugin repeatedly — 34 `loading plugin`
entries in one process's log — and every live instance's `ctx.event.subscribe()` sees the same
terminal event, so one real close reached `flush-run.sh` as many times as there were instances.

The same defect exists on the abandon path for a different reason: `hk_sweep_stale` runs from every
`open-run.sh`, across every session, so two prompts landing in different sessions within the same
instant can both decide to sweep the SAME stale file. `end-run.sh` and `open-run.sh`'s own
per-session reclaim call `hk_flush_abandoned` too — three entry points, one run file, the same race.

**The fix is a single new primitive, shared by both:** `hk_claim_close <run_file>`, in `lib.sh`,
right next to the other sidecar helpers:

```sh
hk_claim_close() {
  ( set -C; : > "$(hk_closing_file "$1")" ) 2>/dev/null
}
```

`>` under `set -C` (noclobber) opens with `O_EXCL` — atomic at the filesystem level, not merely
"usually fine": stress-tested directly, 50 truly concurrent subshells racing to create the same
marker produced exactly 1 winner, every trial, under both bash and dash. No lock library, no new
dependency, and it behaves identically under bash 3.2.

`flush-run.sh` claims immediately after `hk_close_signal` confirms this Stop really is the close —
before any of the semantic derivation (duration, `task_summary`, `project_md`, `drift_fired`) that
used to run on every racing invocation. `hk_flush_abandoned` claims right after its existing
`[ -f "$f" ]` guard. A losing invocation's `>` fails, and it exits/returns clean: the close it
wanted already happened elsewhere, which is not an error. `hk_run_clear` now also removes the
`.closing` marker, so a later run reusing the same session id starts with a clean slate.

Verified with two new `test-hooks.sh` cases, each firing six genuinely concurrent invocations at
one closeable/one stale run and asserting exactly one `runs.jsonl` line survives — the real bug's
shape, reproduced deliberately rather than waited for. Verified by mutation, once per call site:
removing either `hk_claim_close` call makes its own concurrency test fail by name (`6 lineas, no
1`) and touches nothing else; restored, both suites are green (`test.sh` 141/141, `test-hooks.sh`
290/290, stable across five repeated runs). `shellcheck -x --severity=style` clean.

The two duplicate lines already sitting in this machine's real `runs.jsonl` (one from this
incident, one older one from schema 1) were left as-is rather than silently rewritten — the log is
append-only by convention, and a decision to prune real history belongs to whoever reads that log,
not to the fix that stops it from recurring.

## The installer would have broken the V2 setup it never knew existed

A status audit found `./install.sh --tool=opencode` still wrote V1's shape unconditionally: the
loose `plugins/iamlazy.ts` (which a V2 daemon cannot load at all) and `commands/iamlazy.md` (which
duplicates the `/iamlazy` command V2's own plugin registers). `--check` already disagreed with
reality on this machine — `BAD adapter up to date: not installed (…/iamlazy.ts)`, because what was
actually installed and working was `iamlazy.js` — and running the installer again would have
overwritten the validated V2 setup with a broken one.

Three decisions were settled with the human before touching any code, because each is a real fork
with a consequence, not an implementation detail:

1. **Detection is an explicit `--tool=opencode-v2` flag, never auto-selected.** `auto` still only
   ever picks V1's `opencode`. Reasoning offered and accepted: `opencode --version` is the honest
   detection source in principle, but on this very machine the real binary lives in `~/.opencode/bin`,
   outside the default `PATH` — auto-detection would have failed silently and fallen back to V1
   without saying so.
2. **The installer builds only from a real checkout.** `curl|bash` has neither a `.git` nor
   `adapters/opencode-v2/package.json` to build from, so `--tool=opencode-v2` refuses cleanly there
   (checked before `bun` is even probed) rather than deploying something broken. Shipping a
   pre-built `dist/iamlazy.js` committed to the repo was the alternative, rejected because it
   contradicts "a build output is not the source of truth" and would drift from `hooks/` silently
   with no CI step regenerating it.
3. **This does not promote OpenCode V2 out of "candidate" status.** The explicit, never-auto flag
   from decision 1 is exactly what keeps it that way — `PROJECT.md`'s language did not need to
   change to stay true, only to describe what the installer can now do when asked.

**What changed:** `install_opencode_agents`/`install_opencode_review_command` factor out the
templates V1 and V2 share (the prompt body and Critic are identical on both — confirmed live, a
real V2 run used the pinned `OC_CRITIC_MODEL` exactly like V1). `install_opencode_v2_hooks` builds
via `adapters/opencode-v2/build.sh`, and — like `install_opencode_hooks` in the other direction —
removes the OTHER version's adapter shape first: OpenCode auto-discovers every loose file in
`plugins/`, so switching between V1 and V2 on one machine must never leave both. V2 also removes a
stale `commands/iamlazy.md` from a prior V1 install, the exact duplication the original migration
had to fix by hand. `--check` gained a V2 branch: since the deployed file is a bundle, comparing it
byte-for-byte against source would mean rebuilding inside a read-only check (network `bun install`
included) — instead it verifies the invariants a bad V2 install actually broke in production (no
stale V1 shape, no duplicate command, the bundle carries no unresolved `@opencode/plugin` import).
`uninstall.sh` now removes `plugins/iamlazy.js` too.

**A build detail that mattered:** `bun build` strips top-level comments, including the
`iamlazy-managed` marker every generated file carries — `write_file` and `uninstall.sh` both key
off it to know a file is theirs. Without it, a rebuilt bundle would look "not ours" on the next
install and silently stop updating. `build.sh` now prepends the marker back after bundling (a
leading `//` comment is valid anywhere in JS, so this is a no-op for the daemon).

**Verification, on top of the usual full-suite runs:** a real install into a temp `HOME` (agents,
review command, hooks, and the bundle all correctly written; `commands/iamlazy.md` correctly
absent); switching V1→V2→V1 on the same machine twice, asserting neither adapter shape nor the
duplicate command file survives a switch; `--check` and `uninstall.sh` against the result; the
`.git`-less refusal and the missing-`bun` refusal, each simulated directly. Five mutations, one per
new behavior (V1-side stale-V2 cleanup, V2-side stale-V1 cleanup, V2-side command cleanup, the
marker re-add, the `.git` refusal): each kills exactly the test(s) it should — the marker mutation
correctly cascades into three failures (the marker check itself, `--check`, and `uninstall.sh`
refusing to touch an now-unmarked file), which is the marker doing real work across three
call sites, not test duplication.

**A real, unrelated cost found and fixed along the way:** `adapters/opencode-v2/node_modules`
(213MB once built) made two `test.sh` tests that `cp -R` the whole repo 8+ seconds slower each,
for a directory neither test reads. Replaced with a shared `cp_repo` helper that `tar`-pipes with
an exclude list (`.git`, `node_modules`, `dist`) — full suite: 85.7s → 71.9s.

**What is now, honestly, a heavier `test.sh`:** installing V2 is a hard-required path in the
default suite (bun missing fails loudly, matching the existing V1 adapter test's own convention),
and on a fresh checkout its first run pays a real `bun install`. This is the SAME tension flagged
for wiring the adapter's own `bun test` suite into CI — genuinely not resolved here, only paid
once, for the installer's own coverage, because the acceptance criteria required it.

## The tension left open above resolved itself the moment it was paid once

The previous entry flagged wiring `adapters/opencode-v2/`'s own 6-test `bun test` suite into
`test.sh` as a separate, undecided question — the network cost of a fresh checkout's first
`bun install` felt like a new thing to weigh. It was not: that cost was already being paid, by the
installer coverage added moments earlier in the same file. Adding the adapter's own suite right
after it is not a second network dependency, it is reusing one that already exists.

**What changed:** the two invariant loops (hook existence, "translates and never decides" purity)
that only ever pointed at `adapters/opencode/iamlazy.ts` now run against both adapters explicitly,
plus a new check that V1 and V2 invoke the identical hook set — regression cover for the one thing
that would silently rot if either adapter's hook list drifted from the other's. Right after the
existing "opencode adapter (bun test)" section, a matching "opencode-v2 adapter (bun test)"
section runs `bun test adapters/opencode-v2/iamlazy.test.ts` with the exact same policy: bun
missing fails loudly, never a silent skip. It checks for `dist/iamlazy.js` rather than rebuilding
it — the installer section earlier in the file already built it when bun was available, so this
tests the artifact as it actually sits on disk rather than manufacturing a fresh one to test
instead.

**Verified by mutation, three cases:** a forced-failing assertion appended to
`iamlazy.test.ts` makes exactly "opencode-v2 adapter translation suite fails" fail, nothing else;
a fake hook reference appended to the V2 adapter's source makes exactly the two checks that should
catch it fail (the hook-existence check by name, and the V1/V2 hook-set-equality check, both
correctly, since one V2-only hook breaks both invariants at once). Full suite: 182/182 (+20 from
this ticket), `test-hooks.sh` unaffected at 290/290, `shellcheck` clean.

## Three scans became one, and the fix earned its own regression test

`flush-run.sh` priced a run, tallied its raw token components, and counted which models answered
it with three separate calls — `hk_cost_micro`, `hk_token_components`, `hk_model_counts` — each
walking every `"usage":{` line of the same Claude Code transcript on its own pass. `open-run.sh`
did the same three calls once per run, to capture the baseline the close later subtracts. Timed
against a real 17MB transcript that already exists in this repo's own `~/.claude/projects/`
history: the three separate scans cost **~1.34–1.51s**, on every single `Stop`.

The obvious fix — remember a byte offset, only scan what's new — was rejected on sight. This
project already learned that lesson once: `models_seen`'s baseline is a per-model *count*, not a
transcript position, specifically because a compaction can rewrite the file out from under a
cached offset, and that failure is silent — no error, just a wrong number nobody notices. A
positional cache here would reintroduce the exact bug that fix exists to prevent.

**What changed:** `hk_transcript_scan()` in `lib.sh` is one `awk` pass that produces all three
figures — cost, `{output, cache_write, cache_read}` token components, and per-model message
counts — from the same dedup-by-`message.id` loop the three original functions ran separately.
`hk_models_run` was split into `hk_models_subagents` (sub-agent transcripts, unchanged, still a
separate small scan) so `flush-run.sh` and `open-run.sh` can feed the scan's own model tally
straight into `hk_models_sum` instead of re-scanning the main transcript a second time. Neither
caller keeps any state between calls — every `Stop`, and every `open-run.sh` baseline, is a full
fresh read of the transcript as it exists *right now*. There is nothing to invalidate, because
nothing is remembered.

**Measured, not estimated:** end-to-end on `flush-run.sh` itself, same real 17MB transcript, three
runs each. Before: 2.29s / 2.06s / 1.87s. After: 1.01s / 1.00s / 0.99s — a real **~2.05x** speedup
on the whole hook (the merged scan alone, isolated from the rest of the hook's own overhead, went
from ~1.46–1.51s to ~0.58–0.59s, ~2.5–2.6x). The circuit breaker (Guarantee 5) still evaluates on
every turn — this only cut how long it takes to get there.

**Verified by mutation:** a new `test-hooks.sh` case calls `hk_transcript_scan` on one path, then
overwrites that *same path* with a smaller transcript naming a different model — a stand-in for a
compaction — and asserts the second call reflects only the new content. Deliberately reintroducing
exactly the rejected fix (a cache keyed on the transcript's path, written after the first real scan
and served back verbatim on every later call for that path) made this new assertion fail as
expected, and also broke five *pre-existing* drift/breaker/cost tests that reuse one transcript
path across several `flush-run.sh` calls within a single test — the same shape of bug the ticket
worried about, catching itself in the existing suite before the new test even had to. Reverting
restored a clean run: `test-hooks.sh` 292/292 (+2 from this ticket), `test.sh` 182/182 unaffected.

## 2026-09-16 — closing the OpenCode V2 gap audit

Four gaps from the V2 audit, closed together. The installed machine was also brought back in sync
first (`./install.sh --check` had been failing: five shared hooks behind the repo, and the deployed
bundle not recognized as installer-owned). That last one was the installer refusing to overwrite a
file that lacked the `// iamlazy-managed` marker — correct behavior, since the deployed bundle was
the one hand-built before `build.sh` started re-adding the marker `bun build` strips. Backed it up,
removed it, reinstalled.

**`patch` edits escaped Layer 0 entirely.** V2's `patch` tool applies a whole apply_patch document
in one call. It matched no branch in `execute.after`, so every file it wrote was invisible to
`track-edit.sh` — no journal line, and nothing for the scope gate to check. The shapes were read
from the v2.0.1 binary's own parser rather than guessed: input is `{patchText}`, result is
`{output: {applied: [{type, resource, target}], files}}`, and the valid headers are
`*** Add File: {path}`, `*** Update File: {path}`, `*** Delete File: {path}` plus `*** Move to:
{path}`. Two sources are unioned because neither is complete: `applied[].target` is absolute and
authoritative for what was written, but a MOVE reports only its destination — the source it emptied
appears nowhere except the patch headers. Relative headers resolve against a base derived from an
applied entry (`target` minus `resource`), not the session cwd: a run opened through the API records
`cwd=$HOME` even when the project lives elsewhere, which was observed directly, not assumed.

**Background sub-agents are now refused by Layer 0, not the prompt.** V2 can launch a delegation
with `background: true`; the tool returns `"running"` immediately and the work finishes out of band,
so findings never arrive through `SubagentStop`. The old path recorded `critic_asked` and then let
the run close as a "declared deviation" — which reads as *no review was attempted* when one was
actually still running. That is the silent degradation Layer 0 exists to remove, so the denial lives
in `guard-agent.sh` (via the existing `hk_bool_true`), placed BEFORE the Critic branch so a refused
attempt records nothing. It stays host-neutral: the adapter already forwarded the field through its
spread, and Claude Code's Agent tool simply never carries it. Matching `true` anywhere in the
payload is the fail-safe direction, same reasoning as the `subagent_type` ambiguity denial.

**Both completion vocabularies, one flush.** The adapter accepted only
`session.execution.{succeeded,failed,interrupted}`. `session.idle` is a real, declared event in the
same protocol version's schema, so a later build may emit it — possibly alongside. Capturing the raw
SSE stream during a real turn on this daemon showed exactly one `session.execution.started` and one
`session.execution.succeeded`, and no `session.idle` at all. Both vocabularies are accepted now,
gated by an in-flight turn marker set from three independent places (the prompt hook, the `/iamlazy`
command, and `session.execution.started`) and cleared by whichever completion event arrives first.
Layer 0 would survive a double flush anyway — `hk_claim_close` makes the close atomic — but the
block path would still inject two synthetic messages into the session for a single turn, which the
human would see.

**Cleanup is now actually exercised.** The migration checklist requires proving teardown on reload
or removal. The test mock previously ignored the `AbortSignal`, which meant a cleanup that never
unsubscribed would have passed silently; worse, it would have hung. The mock honors the signal now,
and the new test drives the returned cleanup function, asserting the subscription terminates, that
opened runs get `end-run.sh`, and that events pushed afterwards do nothing.

Verified by mutation, one per new behavior, each killing exactly the expected test: disabling the
background denial killed the Critic-background denial and the `critic_asked` assertion (the
Explore-in-background case correctly survived — Explore is denied regardless, so that assertion has
no teeth for this feature and is kept only as a regression guard); dropping `session.idle` killed
both event tests; removing the in-flight gate killed the flush-exactly-once test; removing the
patchText parse killed the move test; resolving against the session cwd instead of the derived base
killed the project-resolution test; emptying the end-run sweep killed the cleanup test; and removing
`controller.abort()` made the cleanup test hang until its timeout — the kill that matters most,
since that is the failure the old mock could not have shown. `test-hooks.sh` 296/296, `test.sh`
182/182, adapter suite 14/14.

**What is NOT verified.** No live `patch` call was observed. The tool is registered in the daemon
with options identical to `edit` (`{codemode: false, permission: "edit"}`), so it is not gated
differently, and no agent in the config restricts tools — but across three attempts the model in
this environment reported `patch` absent from its tool set and declined to call it, correctly
refusing to emulate it with `shell` and report it as the real thing. The branch is unit- and
mutation-tested against shapes read from the daemon binary, not against live traffic. Recorded as
evidence-gated rather than claimed as done.
