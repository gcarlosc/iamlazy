# Sextant

A software-development harness for **Claude Code** and **OpenCode**. It covers the full loop —
understand the request → grounding → plan → implement → post-validation — on both existing and new
projects. No MCP, no plugins, no external dependencies. Just bash and files.

## The mental model (one page)

Sextant is **not** a pipeline of separate agents. It is **one team that lives inside one head**:
a single main thread that adopts **six cognitive postures**, one at a time, switching explicitly
as the work moves forward. The only real second process it ever spawns is the **Critic**, and
only when the change is hard to revert.

Why postures instead of separate agents: what buys quality is that *the one who builds does not
grade their own work*. A separate OS process is one way to get that isolation — an expensive one
for a solo developer (permission failures in async, no resumable context, handoff ceremony that
doesn't pay off). So Sextant gets the isolation cheaply through disciplined **context resets**
between postures, and pays for a real separate process only where discipline isn't enough.

The six postures:

1. **Receiver** — understands the request; asks only the questions that would change the plan,
   each with a recommendation; declares assumptions out loud.
2. **Cartographer** — builds ground truth; reads `PROJECT.md` first, re-explores only what's
   missing; tags facts `[observed] / [inferred] / [assumed]`; treats empty tool output as
   *uncertain*, not as a confirmed negative.
3. **Designer** — proposes the approach and a verifiable plan; its ground truth is only
   `PROJECT.md` + the Cartographer's findings; every factual claim carries a source or a
   re-verify command.
4. **Builder** — writes code against the **approved** plan; stops and reports on any deviation
   that contradicts the plan.
5. **Critic** — adversarial, read-only review against intent, `PROJECT.md`, and a security lens
   when the surface is sensitive. The only real sub-agent, used conditionally.
6. **Validator** — verifies in the real environment, confirms with the human, proposes the
   `PROJECT.md` update (diff first), closes out.

**Ground truth lives in `PROJECT.md`** at the repo root, versioned with your code. Sextant reads
it at the start of every session, proposes creating it if it's missing, and **never edits it
without showing the diff and getting your approval.**

**Ceremony is calibrated by reversibility**, not by size:

| Reversibility | Example | Flow | Critic |
|---|---|---|---|
| **High** (~30s to undo) | typo, log line, copy | Builder → inline check | inline |
| **Medium** (undo with git) | scoped feature, local refactor, new isolated project | Receiver → Cartographer → Designer → **[approve plan]** → Builder → Critic → Validator | same-thread reset |
| **Low** (not easily undone) | architecture, migration, auth, data, prod deploy | full flow, explicit detailed plan gate | **fresh-context sub-agent** |

Sextant declares its reversibility estimate in one line up front — **that's the first thing you
can correct**, and it recalibrates without argument.

## Install

Clone and run (fully offline):

```sh
git clone <repo> sextant && cd sextant
./install.sh
```

Or force a specific tool:

```sh
./install.sh --tool=claude      # or --tool=opencode  or  --tool=both
```

`curl | bash` (set the raw file base URL of your fork/repo):

```sh
SEXTANT_RAW_BASE="https://raw.example/sextant/main" curl -fsSL https://raw.example/sextant/main/install.sh | bash
```

The installer:
- auto-detects `claude` and `opencode`,
- writes the slash commands and the Critic sub-agent to their global config dirs,
- projects `models.conf` into each file's frontmatter,
- is **idempotent** (re-run any time) and **never clobbers** a file that isn't Sextant's,
- creates `~/.sextant/` for the run log.

## Use

```
/sextant <your task>      # runs the full harness
/sextant-review           # shows the last 20 runs, readable
```

You never see internal mechanics — no session ids, no states, no protocol chatter. You see the
reversibility call, the questions (with recommendations), the plan (at the gate), the diff, and
the result.

## Models and credentials

`models.conf` maps models **per tool** — edit it and re-run `./install.sh`:

| Role | Claude Code | OpenCode |
|---|---|---|
| Main thread | `claude-opus-4-8` | `deepseek/deepseek-v4-pro` |
| Critic | `claude-sonnet-4-6` | `deepseek/deepseek-v4-flash` |

> **OpenCode requires a DeepSeek credential that you configure** — an API key in your environment
> or in `opencode.json`. The installer writes the `model` into the frontmatter; it does **not**
> configure credentials.

OpenCode model strings are exactly what `opencode models` lists (`provider/model`). Claude Code
takes bare Anthropic model ids.

## The gate is not optional

On medium/low reversibility, Sextant does **not** write code until you approve the plan. This is
a structural rule in the prompt; the tool's native permission prompts are only a backstop.

**Do not run Sextant under `--dangerously-skip-permissions` (or any bypass mode).** It removes the
safety net the harness relies on. Sextant will warn you if it detects bypass signals and ask for
confirmation before continuing. Sextant installs **no hooks**.

## Uninstall

```sh
./uninstall.sh
```

Removes only files carrying the `sextant-managed` marker. It **never** deletes
`~/.sextant/runs.jsonl` or any `PROJECT.md`.

## What's in the box

```
sextant/
  core/            main prompt body (the 6 postures) + the review command body — single source
  critic/          the Critic sub-agent prompt
  templates/       per-tool frontmatter wrappers (claude-code/, opencode/)
  models.conf      per-tool model map (sourceable KEY="value")
  install.sh       idempotent installer (bash 3.2 compatible)
  uninstall.sh     marker-only removal, preserves your data
```

The prompt body is identical across tools; only the frontmatter differs, and the installer
translates it.
