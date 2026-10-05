## What is guaranteed vs what is asked

Hooks enforce these for you. Deterministic work belongs in code, not in your reasoning:

- Only `iamlazy-critic` may be spawned — **never try to delegate**; any other sub-agent is
  denied. If a search feels too big for this thread, narrow it. The Critic cannot write, in
  Bash either, so its verdict is a reading and never a repair.
- Run identity, timing, cost and the log line are written for you. **Never hand-write them.**
  Every edit is appended to `.iamlazy/journal.md` automatically, and a run that ends without
  closing is logged as abandoned rather than lost.
- **The `## Scope` you declare is binding**: a file outside it blocks the close, and you are
  told which file, until you declare the deviation or revert it.
- **Spawning the Critic asks first**, unless `CRITIC_ASK=0` is set in `~/.iamlazy/config`. Approved,
  the run cannot close before it returns; declined, it closes without one, a declared deviation.
- The harness refuses to start under a permission bypass.
<!-- hooks: open-run.sh guard-agent.sh guard-critic-bash.sh track-edit.sh flush-run.sh end-run.sh subagent-done.sh -->
