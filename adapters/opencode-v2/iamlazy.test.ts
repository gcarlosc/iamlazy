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

async function freshCtx() {
  const hooks: Record<string, any> = {}
  const toolHooks: Record<string, any> = {}
  const promptCalls: any[] = []
  const queue: any[] = []
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
      subscribe: async function* () {
        while (true) {
          if (queue.length) yield queue.shift()
          else yield await new Promise((r) => (resolveNext = r))
        }
      },
    },
  }

  const mod = await import(DIST)
  await (mod.default as any).setup(ctx)
  return { ctx, hooks, toolHooks, promptCalls, pushEvent }
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
test("idle detection uses the real session.execution.* events, not the fictitious session.idle", async () => {
  const { hooks, pushEvent } = await freshCtx()
  pushEvent({ type: "session.created", data: { sessionID: "root4" } })
  await wait()

  // The event names V1's vocabulary suggested do not exist on the real V2
  // event bus (confirmed by capturing its live SSE stream) and must be inert.
  captured = []
  pushEvent({ type: "session.idle", data: { sessionID: "root4" } })
  pushEvent({ type: "session.status", data: { sessionID: "root4", status: { type: "idle" } } })
  await wait()
  expect(captured.find((c) => c.hook === "flush-run.sh")).toBeUndefined()

  for (const t of ["session.execution.succeeded", "session.execution.failed", "session.execution.interrupted"]) {
    captured = []
    pushEvent({ type: t, data: { sessionID: "root4" } })
    await wait()
    expect(captured.find((c) => c.hook === "flush-run.sh")).toBeTruthy()
  }
})
