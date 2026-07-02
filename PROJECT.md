# PROJECT.md — Sextant

Ground truth for this repo. Sextant reads this at the start of every session and proposes updates
(diff first, human approves) when it learns something. Authoritative but correctable: if an
observation contradicts this file, that contradiction gets reported, not silently resolved.

## Purpose

Sextant is a software-development harness for **Claude Code** and **OpenCode**. One main thread
adopts **six cognitive postures** (Receiver, Cartographer, Designer, Builder, Critic, Validator)
across the full loop: understand the request → grounding → plan → implement → post-validation, on
both existing and new projects. It is **not** a pipeline of separate agents.

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
- **Idempotency** via a `# sextant-managed` marker inside each generated file's YAML frontmatter.
- Global install (not per-project), one command, works for both tools.

## Architecture in 10 lines

1. `core/sextant.md` — the main prompt: the 6 postures + all rules.
2. `core/sextant-review.md` — the `/sextant-review` body (reads the run log).
3. `critic/sextant-critic.md` — the Critic sub-agent (read-only, fresh context).
4. `templates/claude-code/*` and `templates/opencode/*` — frontmatter wrappers only.
5. The Critic is the **only** real sub-agent, spawned **only** on low-reversibility work.
6. Everything else runs in one thread; postures switch via a "baton" + re-reading primary sources.
7. Ground truth lives in each target project's `PROJECT.md` (this file is Sextant's own).
8. Ceremony is calibrated by **reversibility** (high/medium/low), not size or greenfield.
9. Observability: one JSON line per task appended to `~/.sextant/runs.jsonl` (tmp→flush).
10. `install.sh` / `uninstall.sh` manage global config for both tools; uninstall preserves data.

## Decisions (mini-ADRs)

- **Postures, not separate agents** (2026-07-02). Why: separate async sub-agents suffer permission
  failures, no resumable context, and handoff ceremony that doesn't pay for a solo dev. The
  quality comes from the *posture* (the builder doesn't grade its own work), not from separate OS
  processes — so we buy isolation cheaply via disciplined context resets.
- **One real sub-agent: the Critic, conditional** (2026-07-02). Why: true fresh context is only
  needed where in-thread discipline isn't enough — low-reversibility work.
- **Per-tool models** (2026-07-02). Claude Code: `claude-opus-4-8` (main) / `claude-sonnet-4-6`
  (critic). OpenCode: `deepseek/deepseek-v4-pro` (main) / `deepseek/deepseek-v4-flash` (critic).
  DeepSeek ids verified against `opencode models` (not invented). OpenCode needs a
  user-configured DeepSeek credential; the installer writes the model, not credentials.
- **Context "reset" = disciplined re-grounding** (2026-07-02). Why: within one thread there's no
  real memory wipe. The baton carries conclusions + pointers only; the new posture re-reads
  primary sources. Structural independence exists only in the subagent Critic.
- **Marker-based idempotency + anti-clobber** (2026-07-02). Why: safe re-runs; never overwrite a
  file that isn't ours; uninstall removes only marked files.

## Invariants (do not break)

- The Critic sub-agent **never** has write/edit permission. Bash is read/test only.
- `PROJECT.md` is **never** edited without showing the diff and getting approval.
- On medium/low reversibility, **no code is written before the human approves the plan.**
- Sextant installs **no hooks** and must not be run under `--dangerously-skip-permissions`.
- `uninstall.sh` **never** deletes `~/.sextant/runs.jsonl` or any `PROJECT.md`.
- Empty tool output is never treated as a confirmed negative (second independent method required).

## Debt and known risks

- **No automated tests, and the harness's runtime behavior is not executed in CI.** Only install,
  file composition, and installer logic are verified (end-to-end in an isolated HOME). The 6
  postures are correct *by construction of the prompt*, not by a live `/sextant` run.
- **OpenCode directory + frontmatter conventions are trusted from this machine** (`agents/`,
  `commands/`, `mode:`, `permission:`). If OpenCode changes these, the installer needs updating.
- **`curl | bash` requires `SEXTANT_RAW_BASE`** pointing at a raw file base URL; the offline path
  is clone+run.
- **The run log assumes one active session at a time** (tmp→flush orphan recovery).
