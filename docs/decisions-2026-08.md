# Decisions archive — 2026-08

Moved out of PROJECT.md on 2026-08-25, when Layer 0 landed and PROJECT.md was
rewritten to describe the harness as it now is rather than how it got here.
These entries are the reasoning behind that history and are not re-litigated.

## Decisions (mini-ADRs)

Consolidated 2026-08-22. Foundations are one line each — they are settled and the code shows the
detail. Recent entries keep their reasoning; evidence tables live in `DELTAS.md`, not here.
**An ADR records a decision that changes the design.** Implementation changes belong in the commit
message, the README and the prompt — writing one up per edit is what pushed this file past 290
lines in a single session.

**Foundations (2026-07)** — nine settled decisions (artifacts over postures, structure over
discipline, the post-diff floor, pre-verified claims, verbatim persistence, the Critic as sole
sub-agent, marker idempotency, Principles + evidence backlog, rendering discipline). Archived
in `docs/decisions-archive.md`.

**Instrumentation and cost (2026-08)**

- **The run log is a journal, not telemetry** (08-17, corrected 08-19 and 08-22). `runs.jsonl` is
  self-reported: useful for trends, not for auditing one run. `tokens_total` was dropped after being
  wrong in 7/7 runs (up to ~94x off) — it needs an external observer the no-runtime design forbids.
  `session_id` moved to A1 after a glob heuristic picked a stale session. Line-budget rule: a
  shape-line character increase costs ⌈Δchars/95⌉ lines, since context tracks characters.
- **Derivable beats self-reported** (08-22). The log was silently losing records: `cat tmp >> log`
  does not guarantee a trailing newline, so 5 of 28 objects were fused and unparseable. Fixed at
  both ends and the file repaired (backup `runs.jsonl.bak-20260822`). `timestamp` (21/28 had round
  `:00` seconds) now comes from `date -u`; `human_interventions` from counting the literal transcript
  marker; `outcome` is constrained, after 28/28 runs reported `success` and the field said nothing.
  Still self-reported by design: `critic_findings_count`, `retries`, `gate_verdict`, `reversibility`.
  Cost joined the derivable set as **`tokens_weighted`** — deliberately not the old `tokens_total`
  name, since it measures something else. Counts come from the session transcript via `grep`+`awk`,
  weighted (output ×5, cache_creation ×1.25, cache_read ×0.1), and feed both the log and A5's
  closing report. This reverses the 08-19 removal: `tokens_total` was dropped as needing "an
  external observer the no-runtime design forbids", but the transcript **is** that observer — only
  the *estimation* was impossible, not the measurement. It unblocks Candidates 9 and 10, whose
  triggers both compare cost per changed line and until now needed hand computation.
- **Session length is the real cost lever** (08-19). ~97.6% of spend is `cache_read` over accumulated
  context: cost per turn rose from ~100k (81–103 turns) to ~233k (447 turns). Splitting one long
  session into several short ones projects to roughly half the tokens — which only works if runs hand
  off by file. Every decomposition decision below follows from this.
- **Decomposition: cut on verification; the Plan is its own ledger** (08-19, revised 08-22). The cut
  test is *can one command verify the whole job?* — one command means one Plan, several independent
  verifications mean per-step delivery. The original design put step results in a separate
  `.iamlazy/steps.md`; that file is gone. Progress belongs in the artifact that already lists the
  steps, so a step is marked done in `.iamlazy/plan.md` with its result appended under it. Removed by
  supersession, not by Candidate 8's eviction trigger, which never fired.

**Models and delegation (2026-08)**

- **iamlazy is out of scope for the host's delegation rules** (08-20). The single-thread model was
  fiction under Claude Code: a global `CLAUDE.md` "Agent Teams Lite" block declared delegation
  triggers non-skippable, and a global file outranks a command prompt. Measured on 3 sessions,
  delegated *builder* agents cost 113% and 122% of their main session and never reach `runs.jsonl`.
  Resolution: a precedence clause outside the `gentle-ai:*` markers so a sync cannot regenerate it
  away. Honest limit: prose, not structure — denying `Task` would also kill the Critic. Detection is
  the fallback: any sub-agent transcript other than the Critic's is evidence of a violation.
  Percentages are cost-weighted (`cache_read` × 0.1); raw sums overstate spend ~4x.
  **Update 08-22:** the Agent Teams Lite block was removed from that global `CLAUDE.md` (archived
  to `~/.claude/docs/`), so on this machine the conflict no longer exists and the clause is a plain
  statement of the invariant rather than an override of a competing one. The honest limit still
  applies to any other host that declares its own delegation rules.
- **Model scope is the session, not `models.conf`** (08-22, supersedes "strongest for both roles",
  07-02/04). A command's `model:` frontmatter overrides for the **current turn only** — verified in
  the docs — and the gate IS a human turn, so `CC_MAIN_MODEL` covers the planner and the **session
  model** covers the builder. `CC_CRITIC_MODEL` is the exception: a subagent's model holds for its
  whole run. Determinism therefore comes from `"model"` in user or project `.claude/settings.json`,
  and the installer reports whether one is pinned. For planner/builder routing, Claude Code's native
  `opusplan` lands the switch exactly on the gate, which rides on plan mode — no second command
  needed, and a two-command split was evaluated and rejected for buying nothing beyond it. No
  OpenCode equivalent. The old rationale ("the Critic is rare") is refuted: 12 of 28 runs escalated.
  `critic_model` is now recorded (derived) so Candidate 10 — a Critic decorrelated from the builder —
  becomes measurable; it cannot fire until the field varies. Because `opusplan` switches models at
  the gate, A1 now states the running model (derived from the transcript, never guessed) and
  re-states it when it changes: an unannounced switch, or an expected switch that silently did not
  happen, is drift — and this harness exists to make drift visible.

**Self-verification (2026-08-22)**

- **The project checks itself instead of relying on memory.** Three mechanisms landed together
  because they share one failure mode: each depended on a human remembering. `./test.sh` — 42
  assertions, bash 3.2, coreutils only — asserts the declared invariants (the Critic's read-only
  frontmatter, the marker on every template, anti-clobber, uninstall never touching `runs.jsonl`,
  the core budget), and CI runs it on push across Linux and macOS plus a job forcing `/bin/bash`
  so the claimed bash 3.2 support is actually tested. `/iamlazy-review` sweeps every DELTAS
  trigger against the run log and reports which fired. Two details worth keeping: the `--model`
  test runs against a copy, since `persist_model` rewrites `models.conf` in place; and the suite
  was validated by mutation, not by going green. The same audit produced Candidates 12 and 13 —
  the reversibility tier is `medium` in 22 of 28 runs and was never corrected; the gate has
  produced 0 `rejected` verdicts ever — recorded as falsifiable triggers rather than fixes,
  since two readings fit each and the log cannot separate them.
- **Prose instructions get skipped; banners do not** (08-22, from the first real run of these
  changes). A 6-round task ignored two new instructions — declaring the running model, and the
  `cost` line in the closing report — while obeying every structural one, including the banner's
  Critic-mode qualifier. Both skipped items sat in prose inside a bullet and required an extra
  command to produce a datum the human had not asked for. This is the founding ADR's claim
  observed in the wild: prose discipline decays with session length, a required shape does not.
  Fix: the model and effort now ride **in every banner** (`── A3 — PLAN · opus-5 · high ──`),
  which also puts an `opusplan` switch exactly where it happens, and `cost` is marked never
  omitted. Anything else that gets skipped should move into a shape rather than be re-worded.
- Implementation the same day, listed not argued: A4 edits are surgical — match the file's style,
  never "improve" adjacent code or comments, add none of your own unless the file already uses
  them; validation now precedes the Critic in A5 (never
  spend a subagent on code that does not build); A3 names the Critic mode it expects by checking
  paths against the globs; A5 emits a `✓`/`✗` closing report on medium/low; A2 caps recon at ~10
  files / ~15 tool calls; founding decisions moved to `docs/decisions-archive.md`. Details live in
  the core prompt and the README.

**Delegation is a sixth law, not guidance (2026-08-23)**

- **The 08-20 diagnosis was wrong about the cause.** That entry blamed a global `CLAUDE.md`
  "Agent Teams Lite" block for delegated builders. ATL was removed on 08-22 — and two runs the
  next day spawned **7 sub-agents, none of them the Critic**, with ATL provably absent from both
  transcripts. The model delegates on its own; the host's rules were an aggravator, not the cause.
  The real hole was in this project: the prohibition lived in the core's *introduction*, and the
  core states that everything outside the numbered rules is guidance. The single most-violated
  invariant was the one declared as advice. It is now **rule 6**, and it names the escapes
  explicitly — exploration, blast-radius sweeps, "just reading" — because those were the actual
  descriptions used. Measured cost of the two runs: 1.59M and 15.5M weighted, of which 18% and
  21% lived in sub-agents that `runs.jsonl` never sees.
- **A prompt change with no budget invites delegation.** The blast-radius axis added on 08-23
  said "grep across the whole repo, views, jobs, serializers, tests and fixtures included" — and
  the model read that as work worth farming out, spawning five agents named after it. Rewritten
  with a hard budget: the 3–5 riskiest touches, one grep each, in its own context, and say what
  was left unchecked. An instruction that describes unbounded work will get unbounded work.
- **The banner works, and the "it lied" finding was my own measurement error** (corrected 08-24).
  `A1 — BRIEF · opus-4.8 · alto esfuerzo` appeared exactly as specified, and 08-23 recorded that
  the value was invented because the transcript "says claude-opus-5, 71 times". That grep hit a
  **sub-agent** file, not the main thread. The main thread of that session logged
  `claude-opus-4-8` 17 times: the banner was right. Lesson worth more than the original claim —
  under `opusplan` a session legitimately holds three model ids at once (Opus in plan mode, Sonnet
  after the gate, and whatever sub-agents run), so any check must name which file it read. The
  literal-output-or-`?` wording was kept anyway: cheap, and it makes an underived value visible.
- **A compressed command is a broken command.** `tokens_weighted` was absent from run `d6924031`
  even though the instruction was installed. Cause: while fighting the 250-line budget the command
  had been squeezed to `grep -o '"F":[0-9]*' T`, with `F` and `T` as placeholders that were never
  defined anywhere. The model did the honest thing and reported "costo: no disponible para
  reportar con precisión" rather than inventing a figure. Rewritten with the real transcript path
  and an explicit substitution note. Line pressure is real, but a rule compressed past
  comprehension costs more than the lines it saved.
- **The log never wrote.** Both runs closed A5 and neither appended to `runs.jsonl`; no Bash call
  in either transcript touched it, and no orphan `run.tmp.json` was left for the recovery path.
  The flush is the last bullet of the last artifact, in prose, after hours of session. Fix: the
  closing report ends with a bare `log: ok`, which deliberately breaks the "log writes are
  invisible" rule. One visible token is the price of the record existing at all.

**The Critic's job, sharpened (2026-08-23)**

- **Blast radius is the Critic's distinctive work.** The human can test whether a feature works;
  they cannot see what else depends on what changed. That is now an explicit review axis: for
  every symbol, partial, config key, column or route the diff touches, find its other callers
  across the repo and name which were checked — an unchecked caller is not a safe one. Implicit
  contracts count, and that is the point: run `b5b8d46c` changed `<option>` ordering that
  `WspPhoneNumber#next_responsible_id` silently depended on, and it cost the human six rounds to
  find, because a manual test passes right up until production. Axis 1 ("does it do what was
  asked?") duplicates what the human already verified by testing — known, deliberately left.
- **`critic_findings_count` → `critic_findings` "H/M/L/I".** The log recorded how many findings a
  review produced, never whether they were worth anything, so "does the Critic earn its cost?"
  was unanswerable. The one run ever audited was 4 LOW + 2 INFO — zero HIGH, zero MEDIUM:
  suggestive, not conclusive. The Critic now emits its own tally and keeps the four severity tags
  in English whatever the reply language, so the count is read rather than recounted. Prerequisite
  for calibrating the anti-condescension rule, which across 29 runs has never produced zero.

