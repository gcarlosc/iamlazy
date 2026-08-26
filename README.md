# iamlazy

A software-development harness for **Claude Code**. It runs **one task end to end** — analyse,
ask, contract, approve, execute, review — in a single thread. No MCP, no plugins, no external
dependencies. Just bash and files.

## The mental model (one page)

iamlazy is not a pipeline of agents and it does not role-play personas. It is one senior engineer
working one task, with a **contract** in the middle: what you agreed to do, signed before any code
is written, and checked against reality at the end.

It is deliberately **not** built for multi-hour sessions. A long run is a symptom. The worst run in
the log took nearly two hours to produce 230 lines across 3 files, after seven different attempts —
**24x worse per line** than a normal run. Making that visible, and stopping it, is the point.

### Two layers, and the difference matters

The harness separates what it **guarantees** from what it **asks** — because five of its six old
"inviolable rules" were prose, and the single most-violated one was the one declared as law.

| Layer 0 — guaranteed | Layer 1 — asked |
|---|---|
| Hook scripts you cannot bypass | The prompt: judgement |
| Only the reviewer may be spawned | How to analyse, what to ask |
| Run identity, timing and the log line | How to write the contract |
| Every edit traced automatically | Surgical edits, what the reviewer gets |
| No close while a file sits outside the declared scope | Tone, order, conclusions first |
| Refuses to start under a permission bypass | |

The rule that decides where something goes: **can a command tell whether it was honoured?** If yes
and it can be prevented, it is a guarantee. If yes but only afterwards, it is protocol. If no, it is
style — and it is not called law. **Nothing is promoted by being important.**

Prose is not the enemy; *length* is. The short run in the log obeyed every prose instruction,
banner and all. The long ones dropped the log, the banner and the cost line. So Layer 0 does not
police every rule — it guards the **perimeter** that keeps the task bounded, and lets judgement be
judgement.

### The three files

- **`PROJECT.md`** (repo root, versioned) — what the harness knows about your project: where things
  live, which commands work, the constraints, and **what to review here**, which grows with each
  finding. Only what would have shortened reconnaissance, avoided a question, or changed a step gets
  in; anything else is a diary, not memory. Never edited without showing you the diff.
- **`.iamlazy/contract.md`** — the task: ground, resolved questions, discarded options, the declared
  **scope**, the **groups** (each with the command that proves it done), and the load-bearing
  **claims** with their real output. **This is what you approve.**
- **`.iamlazy/journal.md`** — append-only, written as the work happens, never redacted at the end.
  Includes what was tried and **abandoned** — the thing a reviewer can never reconstruct from a diff.

### The flow

1. **Analysis** — reads `PROJECT.md`, explores what is missing, then decides **how the work splits
   into groups**. A group shares a working context, has its own acceptance command, and leaves the
   repo valid alone. If your request is really several tasks, it says so instead of accepting an
   epic as a task.
2. **Questions** — one single block, never rounds, each with a recommendation, and only after
   reconnaissance. **No grey areas:** every step must trace to an observed fact, an answered
   question, or `PROJECT.md`. No step may rest on an assumption.
3. **Contract** — written to disk, in the shape above.
4. **Approval** — your gate, on native plan mode. You read **commands, not paragraphs** — which is
   the answer to why the old gate never once rejected a plan in 27 runs: reading prose is tiring,
   reading `rspec spec/services/rate_limiter_spec.rb` takes three seconds.
5. **Execution** — group by group, re-reading the contract from disk. A path outside the declared
   scope stops the work instead of being absorbed. **Two attempts, then stop:** a second attempt
   must declare what changes in the hypothesis; a third means the hypothesis is wrong.
6. **Review** — always a **separate** read-only sub-agent, never a "reset" of the same thread. It
   gets the contract and journal **as claims to be tested, not context to be trusted**, and
   **derives its own diff** from paths — you do not get to choose what your auditor sees.
7. **Close** — the report, plus the proposed `PROJECT.md` update as a diff.

**What the reviewer is for.** You can test whether the feature works. What you cannot see is *what
else depended on what changed* — so that is its main job: it picks the 3–5 riskiest things the diff
touches, searches for their other callers, and names which it checked and which it left alone.
Implicit contracts count as much as signatures. A list whose order some other feature relies on is a
real dependency even though nothing declares it, and that is precisely the break that survives a
manual test and fails in production. It must produce a real finding or show its adversarial hunt;
a bare "looks good" is an invalid verdict.

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

You never see internal mechanics — no session ids, no states, no protocol chatter. You see one
block of questions (each with its recommendation), the contract with its acceptance commands and
claims (at the gate), the delivery, and the close. Each stage opens with a banner carrying the
model and effort that produced it, so a model switch is visible exactly where it happens.

During a task, `.iamlazy/` at your project root holds the approved contract — persisted
**verbatim as you approved it** — and the journal, for the reviewer to work against and for you to
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

**`*_CRITIC_MODEL` now covers every review.** This used to be the exception rather than the rule:
with three review modes, `inline` and `same-thread-reset` ran *on the main thread* — 17 of 29 logged
runs, 58% — so under `opusplan` most reviews silently happened on Sonnet after the gate, and nobody
chose that. Making the reviewer **always a sub-agent** fixed it as a side effect: a sub-agent's model
holds for its whole run, so what you set here is what reviews your code. It also means reviewer and
builder can be **decorrelated** on purpose — different models have different blind spots, and a
reviewer that shares the builder's cannot see what the builder could not.

> **Heads up:** the `CLAUDE_CODE_SUBAGENT_MODEL` environment variable, when set, silently
> overrides `CC_CRITIC_MODEL`. Unset it if you want `models.conf` to apply.

> **OpenCode requires a DeepSeek credential that you configure** — an API key in your
> environment or in `opencode.json`. The installer writes the `model` into the frontmatter;
> it does **not** configure credentials.

OpenCode model strings are exactly what `opencode models` lists (`provider/model`). Claude
Code takes bare Anthropic model ids.

## The gate is not optional

iamlazy does **not** write code until you approve the contract, except on trivially reversible
changes. On Claude Code the gate rides the **native plan mode** — platform-enforced structure, not
prose imitating it.

**Do not run iamlazy under `--dangerously-skip-permissions` (or any bypass mode).** It removes the
structural gate the harness is built on. With Layer 0 installed this is no longer a request: the
harness **refuses to start** under a permission bypass.

## Layer 0 (opt-in)

```sh
./install.sh --tool=claude --with-hooks
```

This installs the hook scripts and **prints** the `hooks` block for you to paste into
`~/.claude/settings.json`. It deliberately does **not** edit that file: merging JSON without `jq`
over your own config is not a risk worth taking, and this project has no `jq`.

Without the block the harness still runs — but its guarantees go back to being prose, which is the
failure mode the hooks exist to remove. `./uninstall.sh` reclaims the scripts; the settings block is
yours to remove, since it was yours to add.

## Tests

```sh
./test.sh
```

50 assertions over the installer and the declared invariants — file composition, model projection,
idempotency, anti-clobber, `--model`, `--with-hooks`, and that `uninstall.sh` never touches your run
log. It delegates to `./test-hooks.sh`, a further **39 assertions** over Layer 0's runtime decisions,
fed real captured payloads and validated by mutation rather than by going green. Runs in an isolated
`HOME`, so it cannot disturb your setup. Bash and coreutils only, like everything else here.

CI runs it on every push across Linux and macOS, plus one job that invokes it through `/bin/bash`
specifically — that is the bash 3.2 this project claims to support, and `env bash` on a runner
can quietly resolve to a newer one.

What it does **not** cover: a live `/iamlazy` run. The contract, the gate and the review are still
correct by construction of the prompt. Layer 0 closed part of that debt — a hook script reading JSON
on stdin is testable in a way a prompt never was — but the end-to-end path stays unexercised. Worth
knowing before you trust a green run.

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
  hooks/           Layer 0: the guarantees, as bash reading JSON on stdin
  test.sh          50 assertions over the installer and the declared invariants
  test-hooks.sh    39 assertions over Layer 0, validated by mutation
  .github/         CI: the suite on Linux + macOS, and under /bin/bash for bash 3.2
```

The prompt body is identical across tools; only the frontmatter differs, and the installer
translates it.
