# OpenCode V2 adapter

A second, separate OpenCode adapter targeting the native `@opencode/plugin` API (v2.0.x). It does
**not** replace `adapters/opencode/iamlazy.ts` (the V1 adapter, `@opencode-ai/plugin`) -- the two
host APIs are incompatible and `--tool=opencode` still means V1.

`install.sh` and `test.sh` both know about this adapter now, but only behind an explicit opt-in:

- `./install.sh --tool=opencode-v2` builds and deploys it. V2 is **never auto-selected** -- omitting
  `--tool` detects Claude Code and OpenCode V1 only. It also requires a real cloned checkout plus
  `bun`, and refuses cleanly under `curl | bash`, because the bundle has to be built from source.
- `./test.sh` runs this directory's `bun test` suite and checks both adapters for adapter purity and
  for invoking the identical hook set.

That opt-in is the point: OpenCode V2 is a candidate host, not a committed one (see `DELTAS.md` and
`PROJECT.md`'s debt section), so nothing selects it on your behalf.

## Why this needs a build step at all

V1's adapter (`adapters/opencode/iamlazy.ts`) is a loose, dependency-free `.ts` file:
`import type { Plugin } from "@opencode-ai/plugin"` is erased entirely at compile time, so the
file has zero runtime imports and `install.sh` just copies it byte-for-byte.

V2's API is different: it requires calling the real `Plugin.define({...})` function, so
`iamlazy.ts` here has a REAL runtime `import { Plugin } from "@opencode/plugin"`. The real,
running v2.0.1 daemon cannot resolve that import when it dynamically loads a local plugin file or
directory:

```
Cannot find package '@opencode/plugin' imported from .../plugins/iamlazy.ts
```

This happens even with the package correctly installed in an ancestor `node_modules` -- confirmed
against the actual binary, not assumed from docs. Whatever sandboxing the compiled daemon applies
to a dynamically-loaded external file, it does not include normal filesystem module resolution.
`opencode.jsonc`'s `"plugins"` config array does not help either: an entry that resolves to a file
(rather than a directory) is rejected outright with `configured plugin path must be a directory`
and silently excluded.

The fix that actually works: bundle everything -- `@opencode/plugin` and its whole dependency
tree -- into one self-contained `.js` file with zero import statements left for the daemon to
resolve. `build.sh` does exactly that with `bun build --target=bun`.

## Build

```
./build.sh
```

Requires [bun](https://bun.sh). First run does `bun install` (build-time only: `@opencode/plugin`
and its tree are needed to resolve and bundle the source, never at Layer 0 runtime once bundled),
typechecks `iamlazy.ts`, then writes `dist/iamlazy.js`. `dist/` and `node_modules/` are gitignored;
`bun.lock` is committed for reproducible builds.

## Deploy

1. Copy `dist/iamlazy.js` to `~/.config/opencode/plugins/iamlazy.js`.
2. Remove any other `iamlazy.ts` / `iamlazy/` file or directory from that same `plugins/` folder
   first -- OpenCode auto-discovers every loose file directly inside `plugins/`, so leaving the old
   one there loads it a second time (and it will fail to load, per the section above).
3. Do **not** list it in `opencode.jsonc`'s `"plugins"` array as a bare file path; see above for
   why that entry is silently ignored. A loose file in `plugins/` is auto-discovered without it.
4. Restart the daemon (`opencode service restart`) if one is already running. Confirmed against
   the real daemon: a plugin's load-failure state is cached for the running process's lifetime --
   neither editing the file nor hitting `POST /api/plugin/await-activation` re-evaluates it. Only a
   restart (or a fresh `opencode serve` instance) re-attempts the load.
5. Verify it actually loaded before trusting it:
   `opencode api GET /api/plugin --param 'location[directory]=<your project>'` should show
   `"id":"iamlazy"` with `"state":{"status":"active"}`, and
   `opencode api GET /api/command --param 'location[directory]=<your project>'` should list
   `iamlazy`. Typechecking and a standalone `bun build` passing is NOT proof of this -- see the
   root-cause section above.

## Test

```
bun test iamlazy.test.ts
```

Tests import `dist/iamlazy.js` (the built artifact), not the source -- the entire reason this
adapter is bundled is that the source's `@opencode/plugin` import cannot be resolved by the real
host when loaded dynamically, so a suite that only ever imported the source would never have
caught that. Run `./build.sh` first; the suite refuses to run against a missing bundle rather than
silently testing nothing.

## What this adapter fixes, relative to a straight V1-to-V2 port

An earlier V1→V2 port (by a different agent) had the daemon-load failure above plus six functional
regressions, all confirmed by an independent read-only review and then fixed and verified here
(mocked, mutation-tested, and against a real end-to-end `/iamlazy` run with genuine model traffic):

1. **Subagent guard bypass.** V2 names the tool `subagent` and carries its target as `input.agent`;
   Layer 0's `guard-agent.sh` only recognizes `tool_name` in `{Agent,Task}` and reads
   `subagent_type`. Both are normalized before calling the guard.
2. **Edit/write tracking silently skipped.** V2's `edit`/`write` tools carry the target file as
   `input.path`, not Claude Code's `filePath`/`file_path`.
3. **Cost inflation.** `session.usage.updated` supplies running SESSION TOTALS, not per-update
   deltas; `host-cost.sh`'s contract is purely additive. Forwarding totals verbatim summed $1 then
   $3 into a recorded $4. Fixed with a per-session baseline that is never reset at run-open (so a
   second run in the same session is also correct for free), and model attribution now comes from
   the originating (possibly child) session, not always the root.
4. **Critic completion discarded.** The completion path required `input.subagent_type`, which V2
   never sends (`input.agent` instead), so `critic_done` and the findings sidecar were never
   recorded even after a real review.
5. **Prompt attachments dropped.** The `/iamlazy` command executor forwarded only `prompt.text` to
   `session.prompt`, discarding `files`/`agents`/`skills`.
6. **Idle/close never fires.** Discovered during the real end-to-end run, not by the original
   review's mocks: the adapter listened for `session.idle` / `session.status`, and this daemon
   emits neither (confirmed by capturing its raw SSE stream). The real events are
   `session.execution.{succeeded,failed,interrupted}`. See gap 9 below for how the other
   vocabulary was later added back safely.
   Without this, a run opens, tracks edits and the Critic correctly, and then never flushes --
   `flush-run.sh` never gets a chance to run, so the run sits in `~/.iamlazy/active` forever no
   matter what the model prints.

See `docs/decisions-2026-09.md` for the full incident writeup, including how each fix was verified.

## Closed later, from the gap audit (2026-09-16)

7. **`patch` edits escaped the journal entirely.** V2's `patch` tool applies a whole apply_patch
   document in one call, so one tool event can write several files. It matched no branch at all, so
   every file it wrote was invisible to `track-edit.sh` -- and therefore to the journal and the
   scope gate. Now journaled one line per file, from the union of two sources, because neither is
   complete on its own: `result.output.applied[].target` (absolute, authoritative for what was
   written) and the `patchText` headers (`*** Add File:` / `*** Update File:` / `*** Delete File:` /
   `*** Move to:`) -- a move reports only its DESTINATION in the result, so the source it emptied
   appears nowhere else. Relative headers resolve against a base derived from an applied entry
   (`target` minus `resource`), not the session cwd: a run opened through the API records
   `cwd=$HOME` even when the project lives elsewhere.
8. **Background sub-agents could close a run with a review still in flight.** V2 can launch a
   delegation with `background: true`; the tool returns `"running"` immediately and the work
   finishes out of band, so findings never arrive through `SubagentStop`. `critic_asked` was
   recorded anyway, and the run then closed as a "declared deviation" -- reading as *no review was
   attempted* when one was actually still running. Layer 0 now refuses the spawn outright
   (`guard-agent.sh`), before the Critic branch, so a refused attempt records nothing. The adapter's
   job is only to forward the flag intact.
9. **Completion events were single-vocabulary.** The adapter accepted only
   `session.execution.{succeeded,failed,interrupted}`. `session.idle` is a real, declared event in
   the same protocol version's schema, so a later build may emit it -- possibly alongside. Both
   vocabularies are accepted now, gated by an in-flight turn marker so one turn flushes exactly
   once. Without the gate, a build emitting both would inject two synthetic messages for one turn.
10. **Cleanup was never exercised.** The migration checklist requires proving teardown on reload or
    removal. The suite now drives the returned cleanup function and asserts the subscription
    actually terminates, that opened runs get `end-run.sh`, and that post-cleanup events do nothing.

## Why the model usually cannot call `patch`

`patch` registers with `codemode: false`, which keeps it OUT of the Code Mode catalog -- the
`tools[...]` object a model reaches through the `execute` sandbox. Models in this setup drive their
tools through that catalog, so asking one to call `patch` produces:

```
⚙ execute {"code":"const r = await tools[\"patch\"]({ patchText: ... })"}
  Unknown tool 'patch'. The tool may have been removed or renamed.
```

which reads as "the tool does not exist" and is why two different models on two different providers
both reported it missing while offering `edit`/`write`. It is not an agent `tools:` restriction
(none is configured), not the permission filter (`patch` and `edit` share `permission: "edit"`), and
not a broken definition -- dumping the live registry from a plugin shows `patch` present with a
valid 1086-character description and options identical to `edit`.

A plugin can expose it by flipping that one option in its own `ctx.tool.transform`:

```ts
editor.update("patch", (tool) => { tool.options = { ...tool.options, codemode: true } })
```

**This adapter deliberately does NOT do that.** Its job is to translate OpenCode's events into
Layer 0's payloads, not to change which tools the host offers a model. The branch is here so the
journal is correct wherever `patch` IS reachable; deciding to make it reachable is the host's call,
not the harness's.

## Verified live

The `patch` branch was confirmed against the real daemon (2026-09-16) by exposing the tool with the
one-line transform above in a throwaway plugin, then running a genuine multi-file apply -- an add
plus a move-with-edit -- inside a seeded run. Layer 0's journal recorded all three paths:

```
2026-09-16T05:55:13Z Patch c.ts         # added
2026-09-16T05:55:13Z Patch renamed.ts   # move destination, from applied[].target
2026-09-16T05:55:13Z Patch a.ts         # move SOURCE, recovered from the patchText headers
```

That third line is the whole reason both sources are unioned: `applied[]` never reports it.

## Known gaps

- `session.idle` handling is forward-looking: the installed v2.0.1 daemon never emits it (confirmed
  twice by capturing its raw SSE stream during a real turn). The support exists so an upgrade cannot
  silently stop closing runs.
- A patch that fails PART WAY through its write phase is not journaled. The tool reports
  `status: "error"` with no result, and the files it managed to write before failing are named only
  inside the error message. Verification and permission failures -- the realistic cases -- happen
  before any write, so nothing is lost there.
