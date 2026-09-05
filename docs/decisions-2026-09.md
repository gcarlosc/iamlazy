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

## What was deliberately not done

- **`critic_findings` derivation.** `SubagentStop` carries `agent_type` and
  `last_assistant_message`, which removes the false positive that blocked this (a transcript grep
  matching the example inside the Critic's own prompt). Scheduled, not done.
- **A `PreToolUse` guard on the Critic's Bash.** Now possible, since hooks receive `agent_type`
  inside sub-agents. Still deferred.
- **Denying edits in a project with no git.** The warning is now emitted once instead of on every
  turn; turning it into a refusal is a behaviour change worth its own decision.
- **Thresholds in a config file.** The breaker's numbers stay hardcoded, so recalibration still
  means reinstalling.
- **OpenCode.** Untouched, still without Layer 0 and without tests. It is now the largest untested
  surface in the repo and needs a decision, not more analysis.
