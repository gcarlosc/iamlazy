import { afterAll, beforeAll, expect, test } from "bun:test"
import { existsSync } from "node:fs"
import { join } from "node:path"

// Tests the BUILT artifact (dist/iamlazy.js), not the source -- the whole
// reason this adapter is bundled is that the source's `@opencode/plugin`
// import cannot be resolved by the real host when loaded dynamically, so a
// suite that only ever imported the source would never have caught that.
// Run `./build.sh` first; this suite refuses to run against a stale or
// missing bundle rather than silently testing nothing.
const DIST = join(import.meta.dir, "dist", "iamlazy.js")
if (!existsSync(DIST)) {
  throw new Error(`${DIST} does not exist -- run ./build.sh before testing`)
}

type Captured = { hook: string; payload: any }
let captured: Captured[] = []
const originalSpawn = Bun.spawn

function mockSpawn() {
  // @ts-ignore -- intercept Layer 0 invocations instead of running real hooks
  Bun.spawn = (cmd: any, opts: any) => {
    const hook = String(cmd[0]).split("/").pop() ?? ""
    ;(async () => {
      const body = await opts.stdin.text()
      captured.push({ hook, payload: JSON.parse(body) })
    })()
    return { stdout: new Response(""), stderr: new Response(""), exited: Promise.resolve(0) }
  }
}

beforeAll(() => {
  mockSpawn()
})
afterAll(() => {
  // @ts-ignore
  Bun.spawn = originalSpawn
})

const ABORTED = Symbol("aborted")

async function freshCtx() {
  const hooks: Record<string, any> = {}
  const toolHooks: Record<string, any> = {}
  const promptCalls: any[] = []
  const queue: any[] = []
  const state = { subscriptionClosed: false }
  let resolveNext: ((v: any) => void) | null = null
  const pushEvent = (e: any) => {
    if (resolveNext) {
      const r = resolveNext
      resolveNext = null
      r(e)
    } else queue.push(e)
  }

  const ctx: any = {
    location: { directory: "/tmp/fake-project" },
    command: {
      transform: async (fn: (editor: any) => void) => {
        const defs: any[] = []
        fn({ add: (d: any) => defs.push(d) })
        ctx.__commandDefs = defs
      },
    },
    session: {
      hook: async (name: string, fn: any) => {
        hooks[name] = fn
      },
      switchAgent: async () => {},
      prompt: async (input: any) => {
        promptCalls.push(input)
      },
      context: async () => [],
      synthetic: async () => {},
    },
    tool: {
      hook: async (name: string, fn: any) => {
        toolHooks[name] = fn
      },
    },
    event: {
      // Honours the AbortSignal, exactly as the real bus does. A mock that
      // ignored it would hang forever inside the adapter's own cleanup (which
      // awaits the event task) and, worse, would let a cleanup that never
      // actually unsubscribes pass as if it had.
      subscribe: async function* (opts: any = {}) {
        const signal = opts.signal
        try {
          while (true) {
            if (signal?.aborted) return
            if (queue.length) {
              yield queue.shift()
              continue
            }
            const e = await new Promise<any>((r) => {
              resolveNext = r
              signal?.addEventListener?.("abort", () => r(ABORTED), { once: true })
            })
            if (e === ABORTED) return
            yield e
          }
        } finally {
          state.subscriptionClosed = true
        }
      },
    },
  }

  const mod = await import(DIST)
  const cleanup = await (mod.default as any).setup(ctx)
  return { ctx, hooks, toolHooks, promptCalls, pushEvent, cleanup, state }
}

async function wait() {
  await new Promise((r) => setTimeout(r, 20))
}

// -------------------------------------------------------- guard normalization
test("subagent guard: V2 tool/field names normalize to Agent/subagent_type", async () => {
  const { toolHooks } = await freshCtx()
  captured = []
  await toolHooks["execute.before"]({
    sessionID: "root1",
    tool: "subagent",
    agent: "iamlazy",
    input: { agent: "builder", prompt: "write" },
  })
  await wait()
  const c = captured.find((c) => c.hook === "guard-agent.sh")
  expect(c).toBeTruthy()
  expect(c!.payload.tool_name).toBe("Agent")
  expect(c!.payload.tool_input.subagent_type).toBe("builder")
})

// ------------------------------------------------------------ edit tracking
test("edit tracking: V2's `path` field reaches track-edit.sh, only when completed", async () => {
  const { toolHooks } = await freshCtx()
  captured = []
  await toolHooks["execute.after"]({
    sessionID: "root1",
    tool: "write",
    status: "completed",
    input: { path: "/repo/src/a.ts", content: "x" },
  })
  await wait()
  const c = captured.find((c) => c.hook === "track-edit.sh")
  expect(c).toBeTruthy()
  expect(c!.payload.tool_input.file_path).toBe("/repo/src/a.ts")

  captured = []
  await toolHooks["execute.after"]({
    sessionID: "root1",
    tool: "write",
    status: "error",
    input: { path: "/repo/src/b.ts" },
  })
  await wait()
  expect(captured.find((c) => c.hook === "track-edit.sh")).toBeUndefined()
})

// --------------------------------------------------------- critic completion
test("critic completion: native V2 agent selector reaches subagent-done.sh", async () => {
  const { toolHooks } = await freshCtx()
  captured = []
  await toolHooks["execute.after"]({
    sessionID: "root1",
    tool: "subagent",
    status: "completed",
    input: { agent: "iamlazy-critic" },
    result: { metadata: { sessionID: "child-critic-1" }, content: [{ type: "text", text: "findings: 0/0/0/0" }] },
  })
  await wait()
  const c = captured.find((c) => c.hook === "subagent-done.sh")
  expect(c).toBeTruthy()
  expect(c!.payload.agent_type).toBe("iamlazy-critic")
  expect(c!.payload.agent_id).toBe("child-critic-1")
  expect(c!.payload.last_assistant_message).toBe("findings: 0/0/0/0")
})

// ---------------------------------------------------------- prompt forwarding
test("command executor forwards files/agents/skills, not just text", async () => {
  const { ctx, promptCalls } = await freshCtx()
  const execDef = ctx.__commandDefs.find((d: any) => d.name === "iamlazy")
  await execDef.execute({
    sessionID: "root2",
    prompt: { text: "Review this", files: [{ uri: "file:///tmp/x.png" }], skills: [{ id: "skill-1" }] },
    delivery: "queue",
  })
  const p = promptCalls[0]
  expect(p.text).toBe("Review this")
  expect(p.files?.[0]?.uri).toBe("file:///tmp/x.png")
  expect(p.skills?.[0]?.id).toBe("skill-1")
})

// -------------------------------------------------------- cost/model deltas
test("usage deltas: cumulative totals become per-event deltas, model attributed per session", async () => {
  const { hooks, pushEvent } = await freshCtx()
  pushEvent({ type: "session.created", data: { sessionID: "root3", location: { directory: "/tmp/fake-project" } } })
  pushEvent({ type: "session.created", data: { sessionID: "child3", parentID: "root3" } })
  await wait()
  await hooks["context"]({ sessionID: "root3", agent: "iamlazy", model: { providerID: "a", id: "main" }, system: [] })
  await hooks["context"]({
    sessionID: "child3",
    agent: "iamlazy-critic",
    model: { providerID: "b", id: "critic" },
    system: [],
  })

  captured = []
  pushEvent({ type: "session.usage.updated", data: { sessionID: "root3", cost: 1, tokens: { output: 10, cache: { write: 0, read: 0 } } } })
  await wait()
  pushEvent({ type: "session.usage.updated", data: { sessionID: "root3", cost: 3, tokens: { output: 30, cache: { write: 0, read: 0 } } } })
  await wait()
  const costCalls = captured.filter((c) => c.hook === "host-cost.sh")
  expect(costCalls.length).toBe(2)
  expect(costCalls[0].payload.cost_micro).toBe(1_000_000)
  expect(costCalls[1].payload.cost_micro).toBe(2_000_000) // the delta, not the $3 cumulative
  expect(costCalls[0].payload.model).toBe("a/main")

  captured = []
  pushEvent({ type: "session.usage.updated", data: { sessionID: "child3", cost: 5, tokens: { output: 1, cache: { write: 0, read: 0 } } } })
  await wait()
  const childCall = captured.find((c) => c.hook === "host-cost.sh")
  expect(childCall!.payload.model).toBe("b/critic") // the CHILD's own model, not the root's
  expect(childCall!.payload.session_id).toBe("root3") // still funnels into the root run
})

// --------------------------------------------------------------- idle/close
test("every completion vocabulary closes a turn: session.execution.* and session.idle", async () => {
  const { hooks, pushEvent } = await freshCtx()
  pushEvent({ type: "session.created", data: { sessionID: "root4" } })
  await wait()

  // This daemon (v2.0.1) only ever emits session.execution.*; session.idle is
  // declared in the same protocol schema, so a later build may emit it and
  // must not silently stop closing runs. Both are accepted.
  for (const t of [
    "session.execution.succeeded",
    "session.execution.failed",
    "session.execution.interrupted",
    "session.idle",
  ]) {
    captured = []
    pushEvent({ type: "session.execution.started", data: { sessionID: "root4" } })
    await wait()
    pushEvent({ type: t, data: { sessionID: "root4" } })
    await wait()
    expect(captured.find((c) => c.hook === "flush-run.sh")).toBeTruthy()
  }
})

test("one turn flushes exactly once, even when both vocabularies fire for it", async () => {
  const { pushEvent } = await freshCtx()
  pushEvent({ type: "session.created", data: { sessionID: "root5" } })
  await wait()

  // The upgrade hazard this guards: a build that emits BOTH for one turn.
  // Without the in-flight gate this flushes twice, and the block path would
  // inject two synthetic messages into the session for a single turn.
  captured = []
  pushEvent({ type: "session.execution.started", data: { sessionID: "root5" } })
  await wait()
  pushEvent({ type: "session.execution.succeeded", data: { sessionID: "root5" } })
  pushEvent({ type: "session.idle", data: { sessionID: "root5" } })
  await wait()
  expect(captured.filter((c) => c.hook === "flush-run.sh").length).toBe(1)

  // And a genuinely new turn still flushes -- the gate suppresses duplicates,
  // not subsequent turns.
  captured = []
  pushEvent({ type: "session.execution.started", data: { sessionID: "root5" } })
  await wait()
  pushEvent({ type: "session.idle", data: { sessionID: "root5" } })
  await wait()
  expect(captured.filter((c) => c.hook === "flush-run.sh").length).toBe(1)
})

// ------------------------------------------------------------ patch journaling
test("patch: every file a multi-file apply touches reaches track-edit.sh", async () => {
  const { toolHooks } = await freshCtx()
  captured = []
  await toolHooks["execute.after"]({
    sessionID: "root6",
    tool: "patch",
    status: "completed",
    input: {
      patchText: [
        "*** Begin Patch",
        "*** Add File: src/new.ts",
        "*** Update File: src/old.ts",
        "*** Delete File: src/gone.ts",
        "*** End Patch",
      ].join("\n"),
    },
    result: {
      output: {
        applied: [
          { type: "add", resource: "src/new.ts", target: "/tmp/fake-project/src/new.ts" },
          { type: "update", resource: "src/old.ts", target: "/tmp/fake-project/src/old.ts" },
          { type: "delete", resource: "src/gone.ts", target: "/tmp/fake-project/src/gone.ts" },
        ],
      },
    },
  })
  await wait()
  const paths = captured.filter((c) => c.hook === "track-edit.sh").map((c) => c.payload.tool_input.file_path)
  expect(paths.sort()).toEqual([
    "/tmp/fake-project/src/gone.ts",
    "/tmp/fake-project/src/new.ts",
    "/tmp/fake-project/src/old.ts",
  ])
  expect(captured.find((c) => c.hook === "track-edit.sh")!.payload.tool_name).toBe("Patch")
})

test("patch: a move journals the source it emptied, which applied[] never reports", async () => {
  const { toolHooks } = await freshCtx()
  captured = []
  await toolHooks["execute.after"]({
    sessionID: "root6",
    tool: "patch",
    status: "completed",
    input: {
      patchText: ["*** Begin Patch", "*** Update File: src/from.ts", "*** Move to: src/to.ts", "*** End Patch"].join(
        "\n",
      ),
    },
    // The daemon reports ONLY the destination for a move.
    result: { output: { applied: [{ type: "update", resource: "src/to.ts", target: "/tmp/fake-project/src/to.ts" }] } },
  })
  await wait()
  const paths = captured.filter((c) => c.hook === "track-edit.sh").map((c) => c.payload.tool_input.file_path)
  expect(paths.sort()).toEqual(["/tmp/fake-project/src/from.ts", "/tmp/fake-project/src/to.ts"])
})

test("patch: relative headers resolve against the project, not the session's cwd", async () => {
  const { toolHooks } = await freshCtx()
  captured = []
  // ctx.location.directory is /tmp/fake-project, but the work is in /work/repo.
  // A run opened through the API really does record cwd=$HOME while the project
  // lives elsewhere, so resolving against the session cwd would journal a path
  // that does not exist and miss the one that does.
  await toolHooks["execute.after"]({
    sessionID: "root6",
    tool: "patch",
    status: "completed",
    input: {
      patchText: ["*** Begin Patch", "*** Update File: src/from.ts", "*** Move to: src/to.ts", "*** End Patch"].join(
        "\n",
      ),
    },
    result: { output: { applied: [{ type: "update", resource: "src/to.ts", target: "/work/repo/src/to.ts" }] } },
  })
  await wait()
  const paths = captured.filter((c) => c.hook === "track-edit.sh").map((c) => c.payload.tool_input.file_path)
  expect(paths.sort()).toEqual(["/work/repo/src/from.ts", "/work/repo/src/to.ts"])
})

test("patch: a failed apply journals nothing", async () => {
  const { toolHooks } = await freshCtx()
  captured = []
  await toolHooks["execute.after"]({
    sessionID: "root6",
    tool: "patch",
    status: "error",
    input: { patchText: "*** Begin Patch\n*** Update File: src/x.ts\n*** End Patch" },
    error: { message: "patch verification failed" },
  })
  await wait()
  expect(captured.find((c) => c.hook === "track-edit.sh")).toBeUndefined()
})

// ------------------------------------------------------- background subagents
test("background delegations still reach the guard, carrying the flag Layer 0 refuses on", async () => {
  const { toolHooks } = await freshCtx()
  captured = []
  await toolHooks["execute.before"]({
    sessionID: "root7",
    tool: "subagent",
    agent: "iamlazy",
    input: { agent: "iamlazy-critic", prompt: "review", background: true },
  })
  await wait()
  const c = captured.find((c) => c.hook === "guard-agent.sh")
  expect(c).toBeTruthy()
  // The adapter must not swallow the flag: guard-agent.sh is what denies it,
  // and it can only do that if the field survives normalization.
  expect(c!.payload.tool_input.background).toBe(true)
  expect(c!.payload.tool_input.subagent_type).toBe("iamlazy-critic")
})

test("a background subagent's tool return is never reported as a completed review", async () => {
  const { toolHooks } = await freshCtx()
  captured = []
  await toolHooks["execute.after"]({
    sessionID: "root7",
    tool: "subagent",
    status: "completed",
    input: { agent: "iamlazy-critic", background: true },
    // Background returns immediately with status "running" and no findings.
    result: { output: { sessionID: "child-bg", status: "running", output: "The subagent is working..." } },
  })
  await wait()
  expect(captured.find((c) => c.hook === "subagent-done.sh")).toBeUndefined()
})

// ------------------------------------------------------------------- cleanup
test("cleanup unsubscribes from the bus and ends the runs it opened", async () => {
  const { ctx, cleanup, pushEvent, state } = await freshCtx()
  const execDef = ctx.__commandDefs.find((d: any) => d.name === "iamlazy")
  await execDef.execute({ sessionID: "root8", prompt: { text: "build a thing" }, delivery: "queue" })
  await wait()

  expect(state.subscriptionClosed).toBe(false)
  captured = []
  await cleanup()

  // The migration checklist requires proving the plugin tears down cleanly on
  // reload or removal, not just that it returns a function.
  expect(state.subscriptionClosed).toBe(true)
  const end = captured.find((c) => c.hook === "end-run.sh")
  expect(end).toBeTruthy()
  expect(end!.payload.session_id).toBe("root8")

  // And the bus is genuinely detached: events after cleanup do nothing.
  captured = []
  pushEvent({ type: "session.execution.started", data: { sessionID: "root8" } })
  pushEvent({ type: "session.idle", data: { sessionID: "root8" } })
  await wait()
  expect(captured.length).toBe(0)
})
