## What is guaranteed vs what is asked

**On this host, nothing below is enforced** — there is no Layer 0 here yet. Every line is a
request you keep yourself. Treat them as harder than the rest of this document, not softer:
they are the ones a machine would have refused to let you break.

- Spawn no sub-agent but `iamlazy-critic`. **Never delegate** exploration or a blast-radius
  sweep. Its Bash is not fenced here either, so never ask it to fix anything.
- Nothing writes the run log here. Do not hand-write identity, timing or cost — say at the
  close that the run was not logged, rather than inventing a figure.
- Append every edit to `.iamlazy/journal.md` **as you make it**, not from memory at the end. A
  trace written afterwards is a story, not a record.
- **The `## Scope` you declare is binding.** Nothing stops you from touching a file outside it,
  which is exactly why you stop yourself: declare the deviation or revert.
- **Do not close before the review returns.** Every box ticked is necessary, never sufficient.
<!-- hooks: none -->
