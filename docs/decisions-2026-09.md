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

Still supposed, to be closed by a real run: that OpenCode loads `~/.config/opencode/plugins/*.ts`
at all (17 MB of log and not one plugin-load line), that `command.execute.before` fires for
markdown commands, that `session.idle` means end-of-turn, and that a `throw` in
`tool.execute.before` shows its message to the model. The gate's `decision: block` is fed back
through `session.promptAsync` as a synthetic user turn, with `stop_hook_active` set on the idle
that follows — the same loop Claude Code runs, on a channel nobody has watched yet.
