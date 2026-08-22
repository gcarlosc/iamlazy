# PROJECT.md — iamlazy

Ground truth for this repo. iamlazy reads this at the start of every session and proposes updates
(diff first, human approves) when it learns something. Authoritative but correctable: if an
observation contradicts this file, that contradiction gets reported, not silently resolved.

## Purpose

iamlazy is a software-development harness for **Claude Code** and **OpenCode**. One main thread
produces **five artifacts** — Brief, Ground, Plan, Diff+deviation note, Close — across the full
loop: understand the request → grounding → plan → implement → post-validation, on both existing
and new projects. It is **not** a pipeline of separate agents, and it does not organize work by
personas: the classic postures survive as a consequence of each artifact's demands, not as
prompt instructions.

## Stack and conventions

- **Pure bash + files.** Zero external deps (no MCP, no plugins, no npm/pip/jq). `curl` only for
  the `curl | bash` install path.
- **bash 3.2 compatible** (macOS default): no `declare -A`, detection probes in POSIX sh, no
  globs inside `[ -f ]` (existence for-loops instead).
- **Prompts are markdown.** The body is a single source (`core/`, `critic/`); per-tool
  `templates/*.frontmatter` wrap it. The installer composes `frontmatter + body` and projects
  `models.conf` into the `model:` field.
- **Generated artifacts default to English** (prompts, comments, README). User-facing chat is in
  the user's language.
- **Idempotency** via a `# iamlazy-managed` marker inside each generated file's YAML frontmatter.
- Global install (not per-project), one command, works for both tools.

## Architecture in 10 lines

1. `core/iamlazy.md` — the main prompt: 5 inviolable rules + 5 artifacts (**hard budget ≤250
   lines**; a new rule must evict another or become structure).
2. `core/iamlazy-review.md` — the `/iamlazy-review` body (reads the run log).
3. `critic/iamlazy-critic.md` — the Critic sub-agent (read-only, fresh context; reads
   `.iamlazy/ground.md` + `.iamlazy/plan.md` from disk, re-runs the Plan's claim commands).
4. `templates/claude-code/*` and `templates/opencode/*` — frontmatter wrappers only.
5. The Critic is the **only** real sub-agent — on low reversibility, or whenever the post-diff
   structural floor fires (sensitive glob match or >400 changed lines).
6. Everything else runs in one thread; artifacts hand off via a "baton" (conclusions +
   pointers) + re-reading primary sources from disk.
7. Ground truth lives in each target project's `PROJECT.md`; per-task Ground/Plan persist in
   the target's `.iamlazy/` (gitignored, overwritten at the next task's gate).
8. Ceremony is calibrated by **reversibility** (high/medium/low), not size or greenfield.
9. Observability: one JSON line per task appended to `~/.iamlazy/runs.jsonl` (tmp→flush).
10. `install.sh` / `uninstall.sh` manage global config for both tools; uninstall preserves data.

## Decisions (mini-ADRs)

- **Artifacts, not postures** (2026-07-04; supersedes "Postures, not separate agents",
  2026-07-02). Why: an abandoned posture is invisible; a missing or malformed artifact is
  visible drift, to the human and to the model. Prose discipline degrades with session length;
  a required shape does not. The six postures remain as a mental model in the README only.
- **Two layers: structure over discipline** (2026-07-04). The gate rides Claude Code's native
  plan mode; the Critic is read-only by frontmatter; A2/A3 are files on disk. Prose reduces to
  5 inviolable rules + guidance, under the 250-line budget.
- **Post-diff structural floor** (2026-07-04). After A4, touched paths are checked against a
  sensitive-glob list and a >400-changed-lines cap; either match escalates the Critic to
  subagent deterministically, announced in one line. Pre-work triage stays human-correctable
  judgment; post-diff escalation is structure. False positives escalate — tokens, never safety.
- **Pre-verified load-bearing claims** (2026-07-04). While composing A3 (read-only, allowed
  in plan mode), the model runs each claim's verification command itself and pastes the real
  output next to the claim. The human reads evidence; re-running is their option, never their
  duty. On low reversibility the subagent Critic re-runs the commands as part of its
  checklist — captured output is never trusted.
- **A2/A3 persisted verbatim post-gate** (2026-07-04). Claude Code's plan mode blocks Write, so
  Ground/Plan are composed as text inside plan mode, gated via plan approval, then persisted to
  `.iamlazy/` as the first post-approval action — byte-for-byte what was approved. The Critic
  reads them from disk, never from memory.
- **One real sub-agent: the Critic, conditional** (2026-07-02; updated 2026-07-04). Why: true
  fresh context is needed where in-thread discipline isn't enough — low reversibility, or when
  the structural floor fires.
- **Per-tool models, strongest for both roles** (2026-07-02; updated 2026-07-04;
  **superseded 2026-08-22**, see below). Claude Code:
  `claude-opus-5` (main + critic). OpenCode: `deepseek/deepseek-v4-pro` (main + critic).
  Rationale: the Critic subagent only runs on the least reversible work — rare enough that
  sharpness beats cost — **a premise the run log refutes: 12 of 28 runs escalated it.**
  Ids verified against `opencode models` on 2026-07-04. OpenCode needs a
  user-configured DeepSeek credential; the installer writes the model, not credentials.
- **Marker-based idempotency + anti-clobber** (2026-07-02). Why: safe re-runs; never overwrite a
  file that isn't ours; uninstall removes only marked files.
- **Principles as design constraints + evidence backlog** (2026-07-12). `PROJECT.md` may declare
  a `## Principles` section — normative preferences, distinct from Invariants (facts). A3 treats
  them as design constraints: deviations must be declared with justification; an undeclared
  deviation is an automatic Critic finding in every mode. The Critic also flags unquantified
  adjectives in plan steps/claims as unverifiable. Distilled from spec-kit's constitution after
  a full read of its methodology and commands; the ideas deliberately not adopted (brief-quality
  checklist, coverage-driven A1 questioning) are recorded in `DELTAS.md` behind evidence
  triggers.
- **Rendering discipline from i-have-adhd** (2026-07-20). Two net-zero edits to the Output
  contract: A3 steps carry a concrete time estimate (min/hr); A5 closes with the single most
  concrete next action instead of a "what remains" list. Distilled from the i-have-adhd skill
  (10 communication rules); adopted only the two that reinforce existing beliefs without
  spending the 250-line budget. Rule 9 (scannable list cap ≤5) is gated in `DELTAS.md` as
  Candidate 3 behind an evidence trigger; rule 10 (no closers) rejected — it conflicts with the
  mandatory artifact banners and closing summary, which are structural signal, not ceremony.
- **Per-run metrics: reconciled, not accumulated** (2026-08-17; corrected 2026-08-19, next
  entry). `runs.jsonl` gained passive instrumentation fields — no behavior change. Three
  proposed fields were dropped as duplicates of existing ones (critic_invoked,
  critic_escalated_by, reversibility_declared). The log is self-reported, not independent
  telemetry — useful for trends, not for auditing a single run. Line-budget rule: a shape-line
  character increase is paid in equivalent lines (⌈Δchars/95⌉), since context cost tracks
  characters, not `wc -l`.
- **Metrics baseline validated: `tokens_total` dropped, `session_id` timing fixed, sequential
  A3 form adopted** (2026-08-19). 7 real runs checked against actual transcripts: `tokens_total`
  was wrong in 7/7 (round, estimated numbers — up to ~94x off real usage). It needs an external
  observer, which the no-runtime design forbids, so the field is removed; reconcile manually
  against `~/.claude/projects/<slug>/*.jsonl` if cost ever matters. `session_id`, previously
  resolved at A5 via a glob heuristic, picked a stale session at least once (confirmed: the run
  logged at 02:58:59 under `1f1314b3` actually ran in `b5d05eb4`) — now resolved once at A1 and
  carried through `run.tmp.json`. The same 7 runs showed 6/7 tripping `floor_triggered: size`
  (760–2034 changed lines) — real evidence tasks routinely don't fit one Plan. That motivated
  the **sequential A3 form** (`T01…TN` when work can't close as one unit), now adopted.
  DELTAS.md Candidate 4's "5 baseline runs" checkpoint is met but deliberately not auto-adopted
  — see DELTAS.md for why.
- **Sequential steps persist to `.iamlazy/steps.md`; cut test is verification, not size**
  (2026-08-19; **`steps.md` superseded 2026-08-22** — the cut test survives, the separate ledger
  does not; see below). The sequential form was prose that could not execute: it told the next step to
  read "the prior step's result" with nowhere to write it, so it would have fallen back to the
  conversation — destroying the mechanism's whole purpose. Added `steps.md` as the ledger,
  appended at each step's close and **exempt from the next-gate overwrite** while a sequence is
  open (otherwise T02's gate would erase T01's result). The decomposition test is now concrete
  and reuses the load-bearing-claims machinery: *can one command verify the whole job?* One
  command → single Plan, do not decompose. Several independent verifications → `T01…TN`. A5 in
  sequential form closes by naming `T<n+1>` as its own `/iamlazy` run. Rationale for that last
  part is measured, not assumed: across 5 real sessions, cost per turn rose from ~100k (81–103
  turns) to ~233k (447 turns) because ~97.6% of spend is `cache_read` re-reading accumulated
  context. Splitting one 447-turn session into ~5 shorter runs projects to roughly half the
  tokens — the saving comes from ending sessions, which only works if steps hand off by file.
- **iamlazy is out of scope for the host's delegation rules** (2026-08-20). The single-thread
  model was fiction under Claude Code: `~/.claude/CLAUDE.md` carries an "Agent Teams Lite"
  orchestrator block whose Mandatory Delegation Triggers ("multi-file write → delegate one
  writer") are declared non-skippable, and a global CLAUDE.md outranks a command prompt.
  Measured on 3 real sessions: delegated **builder** agents (`Write`×12, `Edit`×12, 115 turns —
  not the Critic) cost 113% and 122% of their main session, and none of it reaches `runs.jsonl`,
  which accounts only the main thread. Resolution: a precedence clause in `~/.claude/CLAUDE.md`,
  placed **outside** the `gentle-ai:*` markers so a sync can't regenerate it away. Honest limit:
  that clause is prose, not structure — `allowed-tools` cannot express it, since denying `Task`
  would also kill the Critic. Detection is the fallback: any file under a session's
  `subagents/` other than the Critic's is evidence the exclusion was violated. Method note —
  those percentages are cost-weighted (`cache_read` × 0.1); raw transcript sums are ~95%
  `cache_read` and overstate spend by roughly 4x.
- **Model routing is a session setting, not a `models.conf` field; validation precedes the
  Critic** (2026-08-22). Two corrections from a cross-model review round.
  (a) `models.conf` reaches less far than assumed. A command's `model:` frontmatter overrides
  the model **for the current turn only** — verified in the Claude Code docs — and the session
  model resumes at the human's next prompt. The gate IS a human turn, so `CC_MAIN_MODEL`
  governs the planner (A1–A3) and the **session model** governs the builder (A4–A5); it was
  never doing what the file claimed. `CC_CRITIC_MODEL` is unaffected: a subagent's model holds
  for its whole run. The planner/builder split therefore needs no new command and no new
  sub-agent — Claude Code's native `opusplan` alias (Opus in plan mode, Sonnet on execution)
  lands the switch exactly on iamlazy's gate, because the gate rides on native plan mode.
  Structure over discipline, at zero prompt lines. No OpenCode equivalent exists.
  (b) A5 ordered the Critic's verdict **before** real-environment validation, so a subagent
  Critic could be spent reviewing code that does not build — the harness's most expensive
  single action against its least useful input. Inverted: validation first, a failure
  short-circuits the review. Net zero lines; the budget stayed at 250.
  Open and deliberately not decided: whether the Critic should run a model decorrelated from
  the builder rather than the strongest one — `DELTAS.md` Candidate 10, gated on adding a
  derivable `critic_model` field to `runs.jsonl` first.
- **Derivable beats self-reported; the log was silently losing records** (2026-08-22).
  `runs.jsonl` held 28 JSON objects on 23 physical lines: `cat tmp >> log` does not guarantee a
  trailing newline, so 5 records were fused into their predecessor and unparseable as JSONL.
  Fixed by writing the temp with no trailing newline and appending an explicit one; the existing
  file was repaired in place (backup `runs.jsonl.bak-20260822`). Applying the field audit's own
  rule, three more fields moved off introspection: `timestamp` (was self-estimated — 21 of 28
  had round `:00` seconds, one in local offset instead of UTC) now comes from `date -u`;
  `human_interventions` from counting the literal transcript marker; `outcome` is constrained to
  `success` only with validation passed and a Critic verdict, after 28 of 28 runs reported
  `success` and the field carried no information at all.
- **The backlog checks itself** (2026-08-22). `/iamlazy-review` now sweeps every DELTAS trigger
  against the run log and reports only the ones that fired, naming the runs that fired them. The
  evidence-gating was real but depended on the human remembering to check. The installer mirrors
  `DELTAS.md` into `~/.iamlazy/` so the sweep works from any project; the repo copy stays source
  of truth. A fired trigger still prompts evaluation, never adoption.
- **Model determinism is a settings concern; no phase-split command** (2026-08-22). A two-command
  plan/build split was evaluated and rejected: it buys nothing the `opusplan` session setting does
  not already give, and a second command is a second thing to keep in sync. The durable scope for
  a model is the session — `"model"` in user or project `.claude/settings.json` — so that is
  where the harness points people, and the installer now reports whether one is pinned.
- **`steps.md` superseded: the Plan is its own ledger** (2026-08-22). The separate sequential
  ledger is removed. Not by Candidate 8's eviction trigger, which never fired — by supersession:
  a step's progress belongs in the artifact that already lists the steps. A step is marked done
  in `.iamlazy/plan.md` with its result appended under it, so one artifact carries plan and
  progress and the next-gate overwrite exception collapses to "the Plan survives while it has
  unmarked steps". The cut test (can one command verify the whole job?) is unchanged; only the
  `T01…TN` naming and the second file are gone. Freed lines went back to the 250 budget.
- **`critic_model` recorded; A3 names its expected Critic mode** (2026-08-22). Two additions,
  paid for by evictions — the core stayed at 250. `runs.jsonl` now carries a derived
  `critic_model`: the subagent's frontmatter `model:` when the review ran fresh, otherwise the
  model the thread itself ran on. Without it, DELTAS Candidate 10 (a Critic decorrelated from
  the builder) was unmeasurable — there was no record of which model did the reviewing. It still
  cannot fire until runs accumulate under more than one value: a field has to vary before it can
  discriminate. Separately, A3 now declares the Critic mode it expects, by checking the steps'
  paths against the sensitive globs. This is deliberately **not** structure — there is no diff
  yet, so it is a judgment, and it is stated as an expectation. Its value is timing: the human
  learns the review will escalate before approving the plan, not after the code exists. The
  post-diff floor is untouched and still decides.

## Principles

Normative preferences that govern decisions — distinct from Invariants: an invariant states
what IS, a principle states what we PREFER. A Plan (A3) that deviates from a principle must
declare the deviation and its justification; an undeclared deviation is an automatic Critic
finding, in every Critic mode.

- Zero new dependencies without justification in the plan — bash + files stays the baseline.
- Structure over discipline: prefer platform-enforced mechanisms over prose rules.
- Additions to the core evict something: the ≤250-line budget is design pressure, not a
  number to negotiate.
- Harness changes are evidence-gated: ideas not adopted yet live in `DELTAS.md`, each with a
  trigger observable in `runs.jsonl`; a fired trigger prompts evaluation, never auto-adoption.

## Invariants (do not break)

- The Critic sub-agent **never** has write/edit permission. Bash is read/test only.
- **The Critic is the only sub-agent an iamlazy run may spawn** — on any host tool, regardless of
  that host's own delegation rules. Delegating a writer is drift, not an optimization.
- `PROJECT.md` is **never** edited without showing the diff and getting approval.
- On medium/low reversibility, **no code is written before the human approves the plan.**
- `.iamlazy/ground.md` and `.iamlazy/plan.md` are persisted **verbatim as approved at the
  gate** — never re-worded on the way to disk. Marking a Plan step done and appending its result
  under it is not re-wording: no approved line is ever rewritten.
- The post-diff structural floor (globs + size cap) is **never skipped or negotiated**.
- iamlazy installs **no hooks** and must not be run under `--dangerously-skip-permissions`.
- `uninstall.sh` **never** deletes `~/.iamlazy/runs.jsonl` or any `PROJECT.md`.
- Empty tool output is never treated as a confirmed negative (second independent method required).

## Debt and known risks

- **No automated tests, and the harness's runtime behavior is not executed in CI.** Only install,
  file composition, and installer logic are verified (end-to-end in an isolated HOME). The 5
  artifacts are correct *by construction of the prompt*, not by a live `/iamlazy` run.
- **OpenCode directory + frontmatter conventions are trusted from this machine** (`agents/`,
  `commands/`, `mode:`, `permission:`). If OpenCode changes these, the installer needs updating.
- **`curl | bash` requires `IAMLAZY_RAW_BASE`** pointing at a raw file base URL; the offline path
  is clone+run.
- **The run log assumes one active session at a time** (tmp→flush orphan recovery).
- **Bypass detection is not enforceable from inside a prompt** — the detection logic was
  removed; the core keeps a one-line warning and the README carries the full one. The gate's
  strength on Claude Code comes from plan mode; on OpenCode, from `permission: edit: ask` on
  the primary agent plus the tool's native prompts.
- **The Critic's Bash is a discipline hole**: frontmatter denies the write/edit tools, but Bash
  can write via shell. Accepted so the Critic can run tests; the prompt forbids writes.
- **Self-reported log fields fail selectively, not generally** (2026-08-19; refined 2026-08-21).
  `tokens_total`, `session_id` and `duration_seconds` showed estimation or staleness across real
  runs. But a 5-session audit against transcripts found the failure is not universal:
  `critic_findings_count` was exact (6 reported = "four LOW and two INFO") and `retries` was
  consistent, while `human_interventions` undercounts (1 reported against ≥3 real in
  `1f1314b3`; 0 against 3 in `e48d685e`). The discriminator is what the field asks for:
  introspection fails when it must **estimate a quantity** or when its **definition is
  ambiguous**, and holds when the model **counts discrete artifacts it produced**. Still prefer
  command-derivable fields (`git diff --stat`); for `human_interventions` the derivable
  replacement is the literal `[Request interrupted by user for tool use]` transcript marker.
  See DELTAS.md "Field audit" for the per-field evidence. **Largely closed 2026-08-22**:
  `timestamp` and `human_interventions` are now command-derived and `outcome` is constrained.
  Still self-reported by design: `critic_findings_count`, `retries`, `gate_verdict`,
  `reversibility` — the audit found the first two reliable and the last two are judgments no
  command can produce.
- **`.iamlazy/` is untracked by convention but was tracked in this repo's own git history**
  until 2026-08-19. A prior session had already deleted `ground.md`/`plan.md` from disk and
  half-edited `.gitignore`, but left both uncommitted — the fix was started, not finished.
  Completed 2026-08-19 (`.gitignore` entry + `git rm --cached`). Consistent with the bullet
  above: even when the self-report *is* attempted, follow-through (commit) isn't guaranteed
  without an explicit close.
