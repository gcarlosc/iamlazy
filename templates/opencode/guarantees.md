## What is guaranteed vs what is asked

The `iamlazy` plugin enforces these for you, through the same hooks Claude Code runs:

- Only `iamlazy-critic` may be spawned — **never try to delegate**; any other sub-agent is
  denied. If a search feels too big for this thread, narrow it. The Critic cannot write, in
  Bash either, so its verdict is a reading and never a repair.
- Run identity, timing, cost and the log line are written for you. **Never hand-write them.**
  Every edit is appended to `.iamlazy/journal.md` automatically, and a run that ends without
  closing is logged as abandoned rather than lost.
- **The `## Scope` you declare is binding**: a file outside it blocks the close, and you are
  told which file, until you declare the deviation or revert it.
- **The run cannot close before the review returns.** Spawn the Critic in the foreground: a
  background task returns before it has reviewed anything, and the harness never learns it did.
- Nothing refuses a permission bypass here: OpenCode has no such mode, and the gate asks (§1).
<!-- hooks: open-run.sh guard-agent.sh guard-critic-bash.sh track-edit.sh flush-run.sh end-run.sh subagent-done.sh host-cost.sh -->
