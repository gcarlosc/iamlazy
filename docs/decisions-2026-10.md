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
