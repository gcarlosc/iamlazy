# iamlazy

A software-development harness for **Claude Code** and **OpenCode**. It covers the full loop —
understand the request → grounding → plan → implement → post-validation — on both existing and
new projects. No MCP, no plugins, no external dependencies. Just bash and files.

## The mental model (one page)

iamlazy is **not** a pipeline of separate agents, and it does not role-play personas either.
It is one thread that must produce **five artifacts**, each with a required shape and a size
cap:

1. **Brief** — what is actually being asked; declared assumptions; the questions that would
   change the plan, each with a recommendation — asked only **after** a quick reconnaissance,
   never from ignorance.
2. **Ground** (`.iamlazy/ground.md`) — facts about the system, each tagged
   `[observed] / [inferred] / [assumed]`; empty tool output counts as *uncertain*, never as a
   confirmed negative.
3. **Plan** (`.iamlazy/plan.md`) — verifiable steps, discarded alternatives, and the
   **load-bearing claims**: the 2–3 claims that would invalidate the plan if wrong, each with
   its <10s command **and the command's real output, captured while composing the Plan**.
   The Plan also names the **Critic mode it expects**, so you know before approving whether the
   review will escalate — an expectation, not a promise; the post-diff floor still decides.
   **Your approval gate runs on this artifact** — you read verified evidence and decide;
   re-running the commands is your option, not your duty. When **one command can't verify the
   whole job**, the steps become the unit of delivery — each leaving the repo valid on its own,
   each run as its own `/iamlazy` — and **the Plan is its own ledger**: a step is marked done in
   `.iamlazy/plan.md` with its result appended under it. Runs hand off by written result, never
   by conversation, which is where the token saving comes from: a long session costs about
   twice per turn what a short one does.
4. **Diff + deviation note** — the code against the approved plan; a deviation that
   contradicts the plan stops and reports instead of improvising. Edits are **surgical**: the
   file's existing style is matched, adjacent code and comments are never "improved", and no
   comments are added unless the file already uses them or you ask for them.
5. **Close** — real-environment validation first (a failing build short-circuits the review:
   fix, then review), then the Critic's verdict, then a **closing report** on medium/low
   reversibility: what you asked, what was delivered as a `✓`/`✗` checklist against the Plan's
   steps, deviations, validation, findings by severity, token cost, and the one next action.
   High reversibility gets a single line instead. Then the proposed `PROJECT.md`
   update (diff first, you approve), the run log line.

Why artifacts instead of personas: an abandoned role is invisible, but **a missing or
malformed artifact is visible drift** — to you and to the model. Discipline in prose degrades
over a long session; a required file with a required shape does not. The classic six postures
(receiver, cartographer, designer, builder, critic, validator) still exist conceptually — as
the *consequence* of demanding each artifact, not as prompt instructions.

**Ceremony is calibrated by reversibility**, not by size:

| Reversibility | Example | Artifacts | Gate | Critic |
|---|---|---|---|---|
| **High** (~30s to undo) | typo, log line, copy | Diff only | diff preview | inline check |
| **Medium** (undo with git) | scoped feature, local refactor | all five | plan mode on the Plan | same-thread reset |
| **Low** (not easily undone) | architecture, migration, auth, prod | all five | plan mode + claim review | **fresh-context sub-agent** |

iamlazy declares its reversibility estimate in one line up front — **that's the first thing
you can correct**, and it recalibrates without argument.

**The structural floor.** After the code is written, the touched paths are checked
mechanically (`git diff --stat`) against a sensitive-glob list (`*auth*`, `migrations/`,
`*.tf`, `.env*`, `*secret*`, …) and a size cap (**>400 changed lines**). Either match
escalates the Critic to a **fresh-context sub-agent regardless of the declared tier** —
deterministic, non-negotiable, announced in one line. The fresh Critic re-runs the Plan's
claim commands itself — captured output is never trusted. The Critic must produce a real
finding or show its adversarial hunt; a bare "looks good" is an invalid verdict.

**What the Critic is for.** You can test whether the feature works. What you cannot see is *what
else depended on what changed* — so that is the Critic's main job: for every symbol, partial,
config key, column or route the diff touches, it finds the other callers and names which ones it
checked. Implicit contracts count as much as signatures. A list whose order some other feature
relies on is a real dependency even though nothing declares it, and that is precisely the break
that survives a manual test and fails in production.

**Ground truth lives in `PROJECT.md`** at the repo root, versioned with your code. iamlazy
reads it at the start of every session, proposes creating it if it's missing, and **never
edits it without showing the diff and getting your approval.** When it grows past ~150 lines,
iamlazy proposes a consolidation — also as a diff.

`PROJECT.md` may declare a **`## Principles`** section — normative preferences ("composition
over inheritance", "no new dependencies without justification"), distinct from invariants
(facts). The Plan treats them as design constraints: deviating is allowed only by declaring
the deviation and its justification, and an undeclared deviation is an automatic Critic
finding. When iamlazy proposes creating `PROJECT.md` on an existing codebase, it may propose
principles inferred from observed patterns — tagged as inferences for you to confirm, because
only you know what is deliberate convention and what is historical accident.

## Install

Clone and run (fully offline):

```sh
git clone <repo> iamlazy && cd iamlazy
./install.sh
```

Or force a specific tool:

```sh
./install.sh --tool=claude      # or --tool=opencode  or  --tool=both
```

`curl | bash` (set the raw file base URL of your fork/repo):

```sh
IAMLAZY_RAW_BASE="https://raw.example/iamlazy/main" curl -fsSL https://raw.example/iamlazy/main/install.sh | bash
```

The installer:
- auto-detects `claude` and `opencode`,
- writes the slash commands and the Critic sub-agent to their global config dirs,
- projects `models.conf` into each file's frontmatter,
- is **idempotent** (re-run any time) and **never clobbers** a file that isn't iamlazy's,
- creates `~/.iamlazy/` for the run log.

## Use

```
/iamlazy <your task>      # runs the full harness
/iamlazy-review           # shows the last 20 runs, readable
```

You never see internal mechanics — no session ids, no states, no protocol chatter. You see
the reversibility call, one block of questions (each with its recommendation), the Plan with
its load-bearing claims (at the gate), the delivery, and the close. Each stage opens with an
artifact banner so you always know where the work stands.

During a task, `.iamlazy/` at your project root holds the approved Ground and Plan —
persisted **verbatim as you approved them** — for the Critic to review against and for you to
inspect afterwards. Add `.iamlazy/` to your `.gitignore` (iamlazy proposes it if missing).

## Models and credentials

`models.conf` maps models **per tool** — edit it and re-run `./install.sh`, or set both roles of
one tool in a single command: `./install.sh --tool=claude --model=<id>` (persists the choice to
`models.conf`, then reinstalls). One `--model` targets one tool — Claude Code and OpenCode use
different model-id namespaces.

| Role | Set by | Claude Code | OpenCode |
|---|---|---|---|
| Planner (A1–A3) | `*_MAIN_MODEL` | `claude-opus-5` | `deepseek/deepseek-v4-pro` |
| Builder (A4–A5) | **your session model** | see below | `deepseek/deepseek-v4-pro` |
| Critic | `*_CRITIC_MODEL` | `claude-opus-5` | `deepseek/deepseek-v4-pro` |

**How far `models.conf` actually reaches on Claude Code.** A command's `model:` frontmatter
overrides the model **for the current turn only** — the session model resumes at your next
prompt, and the gate *is* a prompt. So `CC_MAIN_MODEL` covers the planner, and your **session
model** covers the builder. `CC_CRITIC_MODEL` is the exception: a sub-agent's model holds for
its whole run.

**Pin the model where it is durable: settings, not `models.conf`.** With no pinned session model
the build runs on whatever the session happens to default to — the only real source of
non-determinism here. Set `"model"` in `~/.claude/settings.json`, or in a project
`.claude/settings.json`, which takes precedence and reapplies on every launch even over a
`/model` switch:

| You want | Set |
|---|---|
| One model the whole way | `"model": "claude-opus-5"` |
| Strong planner, cheap builder | `"model": "opusplan"` |

`opusplan` runs Opus during plan mode and switches to Sonnet on execution. Since iamlazy's gate
rides on native plan mode, that switch lands exactly on the plan/build boundary — a declared
policy, not a coin flip. **You will see which model is running**: every artifact banner carries
the model and effort that produced it — `── A3 — PLAN · opus-5 · high ──` — read from the session
transcript, never guessed. So the switch at the gate is visible exactly where it happens, and a
switch you expected that never happened is just as visible. `CC_MAIN_MODEL` then acts as a floor: a strong planner even when the
session is on something cheap. There is no equivalent on OpenCode — the primary agent's model
*is* the session model and holds for the whole run.

**`*_CRITIC_MODEL` only covers the sub-agent mode.** The `inline` and `same-thread-reset` reviews
run *on the main thread*, so they use your session model — 17 of 29 logged runs, 58%. With
`opusplan` that means most reviews happen on Sonnet after the gate, regardless of what you set
here. If you want a strong Critic everywhere, pin a strong session model; `opusplan` trades that
away for a cheaper builder. Whether the Critic should instead be *decorrelated* from the builder —
different blind spots, genuinely independent review — is tracked in `DELTAS.md`.

> **Heads up:** the `CLAUDE_CODE_SUBAGENT_MODEL` environment variable, when set, silently
> overrides `CC_CRITIC_MODEL`. Unset it if you want `models.conf` to apply.

> **OpenCode requires a DeepSeek credential that you configure** — an API key in your
> environment or in `opencode.json`. The installer writes the `model` into the frontmatter;
> it does **not** configure credentials.

OpenCode model strings are exactly what `opencode models` lists (`provider/model`). Claude
Code takes bare Anthropic model ids.

## The gate is not optional

On medium/low reversibility, iamlazy does **not** write code until you approve the Plan. On
Claude Code the gate rides the **native plan mode** — platform-enforced structure, not prose
imitating it. On OpenCode, the installed permission config is the backstop.

**Do not run iamlazy under `--dangerously-skip-permissions` (or any bypass mode).** It
removes the structural gate the harness is built on. iamlazy installs **no hooks**.

## Tests

```sh
./test.sh
```

42 assertions over the installer and the declared invariants — file composition, model
projection, idempotency, anti-clobber, `--model`, and that `uninstall.sh` never touches your
run log. Runs in an isolated `HOME`, so it cannot disturb your setup. Bash and coreutils only,
like everything else here.

CI runs it on every push across Linux and macOS, plus one job that invokes it through `/bin/bash`
specifically — that is the bash 3.2 this project claims to support, and `env bash` on a runner
can quietly resolve to a newer one.

What it does **not** cover: a live `/iamlazy` run. The five artifacts are correct by
construction of the prompt, not by test — no automated check exercises the gate, the Critic,
or the structural floor. Worth knowing before you trust a green run.

## Validation

Don't take the harness on faith. During the first month, run a few comparable tasks both
ways — with `/iamlazy`, and with the bare tool plus a good `CLAUDE.md` — and compare three
questions: did the gate catch something real? did any work have to be undone? what was the
total time? Each run logs a `tokens_weighted` figure derived from the session transcript, not
estimated, so cost is comparable across runs. `runs.jsonl` + `/iamlazy-review` are half the
instrumentation — and the review also
sweeps `DELTAS.md`'s triggers against your runs, reporting which ones fired, so the backlog
tells you when it has evidence instead of waiting to be asked. If iamlazy does not clearly win,
the right conclusion is to cut it down, not to defend it.

## Uninstall

```sh
./uninstall.sh
```

Removes only files carrying the `iamlazy-managed` marker. It **never** deletes
`~/.iamlazy/runs.jsonl` or any `PROJECT.md`.

## What's in the box

```
iamlazy/
  core/            main prompt body (5 rules + 5 artifacts) + the review command body
  critic/          the Critic sub-agent prompt
  templates/       per-tool frontmatter wrappers (claude-code/, opencode/)
  models.conf      per-tool model map (sourceable KEY="value")
  DELTAS.md        evidence-gated backlog of ideas deliberately not adopted (yet)
  docs/            archived founding decisions (settled, not re-litigated)
  install.sh       idempotent installer (bash 3.2 compatible)
  uninstall.sh     marker-only removal, preserves your data
  test.sh          42 assertions over the installer and the declared invariants
  .github/         CI: the suite on Linux + macOS, and under /bin/bash for bash 3.2
```

The prompt body is identical across tools; only the frontmatter differs, and the installer
translates it.
