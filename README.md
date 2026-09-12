# iamlazy

[![test](https://github.com/gcarlosc/iamlazy/actions/workflows/test.yml/badge.svg)](https://github.com/gcarlosc/iamlazy/actions/workflows/test.yml)

A software-development harness for **Claude Code** and **OpenCode**. It runs **one task end to
end** — analyse, ask, contract, approve, execute, review — in a single thread. No MCP, no external
dependencies. Bash and files — plus one TypeScript file that lets OpenCode run the same bash.

## The mental model (one page)

iamlazy is not a pipeline of agents and it does not role-play personas. It is one senior engineer
working one task, with a **contract** in the middle: what you agreed to do, signed before any code
is written, and checked against reality at the end.

It is deliberately **not** built for multi-hour sessions. A long run is a symptom. The worst run in
the log took nearly two hours to produce 230 lines across 3 files, after seven different attempts —
**24x worse per line** than a normal run. Making that visible, and stopping it, is the point.

**One thread, and one writer.** The value is the chain — plan, diff, review — held over a *single*
context; split it across delegated agents and each one re-derives what the last already knew. That
is why no sub-agent but the reviewer may be spawned, and why it is a hook rather than a request. A
delegated writer also hides its own cost: `runs.jsonl` accounts the main thread, so work handed off
never reaches the number you would use to judge whether the harness is worth keeping. If a search
feels too big for this thread, narrow it — do not hand it off.

### Two layers, and the difference matters

The harness separates what it **guarantees** from what it **asks** — because five of its six old
"inviolable rules" were prose, and the single most-violated one was the one declared as law.

| Layer 0 — guaranteed | Layer 1 — asked |
|---|---|
| Hook scripts you cannot bypass | The prompt: judgement |
| Only the reviewer may be spawned, and spawning it asks first | How to analyse, what to ask |
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
6. **Review** — always a **separate** read-only sub-agent, never a "reset" of the same thread.
   **Spawning it asks first:** approve it and the run cannot close before it returns; decline it
   and the run closes without one, a declared deviation. It gets the contract and journal **as
   claims to be tested, not context to be trusted**, and **derives its own diff** from paths —
   you do not get to choose what your auditor sees.
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
- installs Layer 0: the hooks, registered in Claude Code's `settings.json`, or behind the plugin
  on OpenCode,
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
| Planner (A1–A3) | `CC_MAIN_MODEL` · **your OpenCode default** | `claude-opus-5` | inherited by the `plan` agent |
| Builder (A4–A5) | **your session model** · `OC_MAIN_MODEL` | see below | `opencode-go/kimi-k2.7-code` |
| Critic | `*_CRITIC_MODEL` | `claude-opus-5` | `opencode-go/deepseek-v4-pro` |

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
the model and effort that produced it — `── CONTRACT · opus-5 · high ──` — read from the session
transcript, never guessed. So the switch at the gate is visible exactly where it happens, and a
switch you expected that never happened is just as visible. `CC_MAIN_MODEL` then acts as a floor: a strong planner even when the
session is on something cheap.

**OpenCode does not split on its own, and the reason is worth knowing.** An agent's frontmatter
`model:` pins that agent, so `OC_MAIN_MODEL` holds for everything running as the `iamlazy` agent.
The gate sends you to OpenCode's built-in `plan` agent for analysis — but that agent pins **no**
model, so it inherits the **live session model**, which entering `iamlazy` just set to
`OC_MAIN_MODEL`. Tab does not reset it. The planner therefore runs on the *builder's* model by
default: measured on a real run, 15 planner messages on `kimi-k2.7-code` while the configured
OpenCode default was `deepseek-v4-pro`. Setting that default does not fix it.

To get the split, pin the built-in agent in your own `opencode.json`:

```json
{ "agent": { "plan": { "model": "opencode-go/deepseek-v4-pro" } } }
```

`models.conf` cannot do it for you — the `plan` agent is OpenCode's, and the installer never
writes user config.

**`*_CRITIC_MODEL` now covers every review.** This used to be the exception rather than the rule:
with three review modes, `inline` and `same-thread-reset` ran *on the main thread* — 17 of 29 logged
runs, 58% — so under `opusplan` most reviews silently happened on Sonnet after the gate, and nobody
chose that. Making the reviewer **always a sub-agent** fixed it as a side effect: a sub-agent's model
holds for its whole run, so what you set here is what reviews your code. It also means reviewer and
builder can be **decorrelated** on purpose — different models have different blind spots, and a
reviewer that shares the builder's cannot see what the builder could not.

> **Heads up:** the `CLAUDE_CODE_SUBAGENT_MODEL` environment variable, when set, silently
> overrides `CC_CRITIC_MODEL`. Unset it if you want `models.conf` to apply.

> **OpenCode requires a credential for its provider that you configure** — an API key in your
> environment or in `opencode.json`. The installer writes the `model` into the frontmatter;
> it does **not** configure credentials, and it cannot reach the `plan` agent's model either.

OpenCode model strings are exactly what `opencode models` lists (`provider/model`). Claude
Code takes bare Anthropic model ids.

## The gate is not optional

iamlazy does **not** write code until you approve the contract, except on trivially reversible
changes. On Claude Code the gate rides the **native plan mode** — platform-enforced structure, not
prose imitating it.

**Do not run iamlazy under `--dangerously-skip-permissions` (or any bypass mode).** It removes the
structural gate the harness is built on. With Layer 0 installed this is no longer a request: the
harness **refuses to start** under a permission bypass.

## Layer 0

Installed and registered **by default**. There is no extra step, and that is on purpose: a
guarantee you have to remember to switch on is not a guarantee, and the failure is silent — two
installs look identical while only one enforces anything.

The installer backs up your `settings.json`, validates the result before replacing it, restores the
backup if anything goes wrong, and **never touches your own hooks or settings**. `./uninstall.sh`
unregisters them again, just as carefully.

```sh
./install.sh --tool=claude --no-hooks   # opt OUT, if you really want to
```

Without them the harness still runs, but every guarantee degrades back to prose — the exact failure
mode Layer 0 exists to remove.

**On OpenCode, Layer 0 is the same bash behind a plugin.** `adapters/opencode/iamlazy.ts` is
installed to `~/.config/opencode/plugins/` and does one thing: it translates OpenCode's events
into the JSON payloads the hooks already read, invokes them, and translates a denial back into
the `throw` that blocks a tool there. It reads no contract, computes no scope and knows nothing
about the breaker — a test greps it for those words and fails if any appears. The one thing that
differs is cost: OpenCode prices every message itself, so the adapter forwards each figure to
`host-cost.sh` instead of the hooks re-pricing the run from `prices.conf`. Two things Claude Code
has and OpenCode does not: a permission-bypass mode to refuse, and a plan mode that denies rather
than asks — the prompt says so on that host instead of pretending parity.

## Tests

```sh
./test.sh
```

Covers the installer and the declared invariants — file composition, model projection, idempotency,
anti-clobber, `--model`, hook registration, and that `uninstall.sh` never touches your run log. It
delegates to `./test-hooks.sh` for Layer 0's runtime decisions, fed real captured payloads and
validated by mutation rather than by going green. Runs in an isolated `HOME`, so it cannot disturb
your setup. Bash and coreutils, plus Bun for the one file that runs under Bun.

The OpenCode adapter is exercised by `bun test` — Bun is OpenCode's runtime, so it is what the
plugin actually runs under. Each test feeds a real OpenCode event to the *installed* plugin and
asserts what the real hooks did on disk; nothing in Layer 0 is mocked. **Bun is required**, and the
suite fails rather than skips when it is missing: a translator nobody ran, reported green, is the
false green the rest of this suite exists to refuse.

The Layer 0 half runs **twice, under a C and a UTF-8 locale**, and discovers which UTF-8 locale the
system actually has rather than assuming one. That is not ceremony: the close-by-banner regex was
written with escaped bytes, which BSD grep honours under C and silently ignores under UTF-8, so it
was dead wherever the hooks really run while CI went green for weeks.

CI runs it on every push across Linux and macOS, plus one job that invokes it through `/bin/bash`
specifically — that is the bash 3.2 this project claims to support, and `env bash` on a runner
can quietly resolve to a newer one. A separate `lint` job runs `bash -n` on every script and
`shellcheck -x` at style severity — source-following, so `lib.sh` and `models.conf` get checked
too, not just the line that sources them. Its first real run found a genuine bug (`hk_rel_path`
silently failing on a project path with a glob character in it), which is the argument for keeping
it at style severity rather than only the defaults. Locally, `git config core.hooksPath .githooks`
installs a pre-push hook that refuses to push a red suite.

What it does **not** cover: a live `/iamlazy` run. The contract, the gate and the review are still
correct by construction of the prompt. Layer 0 closed part of that debt — a hook script reading JSON
on stdin is testable in a way a prompt never was — but the end-to-end path stays unexercised. Worth
knowing before you trust a green run.

## Validation

Don't take the harness on faith. During the first month, run a few comparable tasks both
ways — with `/iamlazy`, and with the bare tool plus a good `CLAUDE.md` — and compare three
questions: did the gate catch something real? did any work have to be undone? what was the
total time? Each run logs a `cost_usd` figure derived from the session transcript and a price
table, not estimated, so cost is comparable across runs — and a `models_seen` tally, so a run is
comparable against what actually answered it rather than what the config said would. `runs.jsonl` + `/iamlazy-review` are half the
instrumentation — and the review also
sweeps `DELTAS.md`'s triggers against your runs, reporting which ones fired, so the backlog
tells you when it has evidence instead of waiting to be asked. If iamlazy does not clearly win,
the right conclusion is to cut it down, not to defend it.

**The same standard applies to the harness itself.** Every idea that sounded good and was not
adopted lives in `DELTAS.md` behind a trigger — the condition, written in advance, under which it
becomes worth re-opening. A fired trigger prompts an **evaluation, never an adoption**, and a
trigger written against a field that no longer exists is retired rather than left looking unfired.
It is the rule the two layers run on, pointed at the backlog: an idea does not get in by being
important, it gets in by being checkable.

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
  adapters/        OpenCode: the plugin that turns its events into those payloads, and its tests
  test.sh          the installer and the declared invariants
  test-hooks.sh    Layer 0's runtime decisions, validated by mutation, in two locales
  .githooks/       pre-push: refuses to push a red suite
  .github/         CI: the suite on Linux + macOS, and under /bin/bash for bash 3.2
```

The prompt body is one source for both tools. The frontmatter differs, and two small inserts —
`{{GUARANTEES}}` and `{{GATE}}` — are filled per host so each one is told the truth about what it
enforces; a test compares that text against the hooks each host actually runs.
