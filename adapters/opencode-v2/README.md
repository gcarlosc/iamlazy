# OpenCode V2 adapter

A second, separate OpenCode adapter targeting the native `@opencode/plugin` API (v2.0.x). It does
**not** replace `adapters/opencode/iamlazy.ts` (the V1 adapter, `@opencode-ai/plugin`) -- the two
host APIs are incompatible, and `install.sh`/`test.sh` still only know about V1. This directory is
deliberately **not wired into either**: OpenCode V2 support is a candidate, not a committed host
(see `DELTAS.md` and `PROJECT.md`'s debt section), so building and deploying it stays an explicit,
opt-in step you run by hand.

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
   review's mocks: the adapter listened for `session.idle` / `session.status`, event names guessed
   from V1's vocabulary that **do not exist** on the real v2.0.1 event bus (confirmed by capturing
   its raw SSE stream). The real events are `session.execution.{succeeded,failed,interrupted}`.
   Without this, a run opens, tracks edits and the Critic correctly, and then never flushes --
   `flush-run.sh` never gets a chance to run, so the run sits in `~/.iamlazy/active` forever no
   matter what the model prints.

See `docs/decisions-2026-09.md` for the full incident writeup, including how each fix was verified.

## Known gaps, carried over from the original review

- Command executor has no `patch` branch (V2's `patch` tool takes a multi-file `patchText`, not a
  single `path` -- a materially different shape from `edit`/`write`). Not part of the reproduced
  regressions above; left as a documented gap rather than a rushed, untested parse of unified diffs.
- Background (non-foreground) sub-agent completion is a separate, unverified compatibility
  boundary -- unchanged from the original review's scope.
