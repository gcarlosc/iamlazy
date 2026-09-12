import { expect, test } from "bun:test"
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

const REPO = join(import.meta.dir, "..", "..")
const HOME = mkdtempSync(join(tmpdir(), "iamlazy-oc-home-"))
process.env.HOME = HOME

const installed = Bun.spawnSync([join(REPO, "install.sh"), "--tool=opencode"], { env: { ...process.env, HOME } })
if (installed.exitCode !== 0) throw new Error(`install.sh failed: ${installed.stderr.toString()}`)

const INSTALLED_PLUGIN = join(HOME, ".config", "opencode", "plugins", "iamlazy.ts")
const pluginModule = await import(INSTALLED_PLUGIN)
const { server } = pluginModule

type Prompt = { path: { id: string }; body: { parts: Array<{ text: string }> } }
type Toast = { body: { message: string } }
const calls = { prompts: [] as Prompt[], toasts: [] as Toast[] }
const client = {
  session: {
    promptAsync: async (o: Prompt) => {
      calls.prompts.push(o)
      return {}
    },
  },
  tui: {
    showToast: async (o: Toast) => {
      calls.toasts.push(o)
      return {}
    },
  },
}

const git = (dir: string, ...args: string[]) =>
  Bun.spawnSync(["git", "-C", dir, "-c", "user.email=t@t", "-c", "user.name=t", ...args])
const mkrepo = () => {
  const d = mkdtempSync(join(tmpdir(), "iamlazy-oc-repo-"))
  git(d, "init", "-q")
  git(d, "commit", "-q", "--allow-empty", "-m", "base")
  return d
}
type Hooks = Record<string, any>
const plugin = (directory: string): Promise<Hooks> =>
  server({
    $: Bun.$,
    client,
    directory,
    worktree: directory,
    project: {},
    serverUrl: new URL("http://127.0.0.1:1"),
    experimental_workspace: { register() {} },
  })

const active = join(HOME, ".iamlazy", "active")
const runFile = (sid: string) => join(active, `${sid}.json`)
const sidecar = (sid: string, ext: string) => join(active, `${sid}.${ext}`)
const read = (p: string) => readFileSync(p, "utf8")
const log = () => (existsSync(join(HOME, ".iamlazy", "runs.jsonl")) ? read(join(HOME, ".iamlazy", "runs.jsonl")) : "")
const logLine = (sid: string) => log().split("\n").find((l) => l.includes(`"session_id":"${sid}"`)) ?? ""

const session = (id: string, parentID?: string) => ({
  id,
  parentID,
  projectID: "p",
  directory: "/",
  title: "",
  version: "1",
  time: { created: 1, updated: 1 },
})
const open = (h: Hooks, sid: string, args: string) =>
  h["command.execute.before"]({ command: "iamlazy", sessionID: sid, arguments: args }, { parts: [] })
const created = (h: Hooks, id: string, parentID?: string) =>
  h.event({ event: { type: "session.created", properties: { info: session(id, parentID) } } })
const assistant = (h: Hooks, sessionID: string, id: string, cost: number, completed = true) =>
  h.event({
    event: {
      type: "message.updated",
      properties: {
        info: {
          id,
          sessionID,
          role: "assistant",
          parentID: "u",
          modelID: "m",
          providerID: "p",
          mode: "iamlazy",
          agent: "iamlazy",
          path: { cwd: "/", root: "/" },
          cost,
          tokens: { input: 1, output: 20, reasoning: 0, cache: { read: 30, write: 40 } },
          time: completed ? { created: 1, completed: 2 } : { created: 1 },
        },
      },
    },
  })
const text = (h: Hooks, sessionID: string, messageID: string, id: string, t: string) =>
  h.event({ event: { type: "message.part.updated", properties: { part: { id, sessionID, messageID, type: "text", text: t } } } })
const idle = (h: Hooks, sessionID: string) => h.event({ event: { type: "session.idle", properties: { sessionID } } })
const before = (h: Hooks, sessionID: string, tool: string, args: unknown) =>
  h["tool.execute.before"]({ tool, sessionID, callID: "c" }, { args })
const after = (h: Hooks, sessionID: string, tool: string, args: unknown, output = { title: "", output: "", metadata: {} }) =>
  h["tool.execute.after"]({ tool, sessionID, callID: "c", args }, output)
const chat = (h: Hooks, sessionID: string, agent: string, t: string) =>
  h["chat.message"]({ sessionID, agent }, { message: {}, parts: [{ type: "text", text: t }] })

const R = mkrepo()
const h = await plugin(R)
const S = "ses_root"
const C = "ses_critic"

test("the installed plugin is the repo's adapter, byte for byte", () => {
  expect(read(INSTALLED_PLUGIN)).toBe(read(join(REPO, "adapters", "opencode", "iamlazy.ts")))
})

test("every export is a function, because OpenCode calls each one as a plugin", () => {
  // It refuses the WHOLE module otherwise -- `Plugin export is not a function`
  // -- and says so only in its own log file, so `opencode debug info` still
  // lists the plugin and nothing on screen suggests Layer 0 is off. That is how
  // a real run on 2026-09-06 produced a perfect contract, a real Critic and an
  // empty runs.jsonl. A string constant next to the hook was all it took.
  const notFunctions = Object.entries(pluginModule)
    .filter(([, value]) => typeof value !== "function")
    .map(([name]) => name)
  expect(notFunctions).toEqual([])
  expect(typeof server).toBe("function")
})

test("command.execute.before /iamlazy opens the run through open-run.sh: host recorded, no transcript, the project as cwd", async () => {
  await open(h, S, "probar el adaptador")
  const run = read(runFile(S))
  expect(run).toContain('"host":"opencode"')
  expect(run).toContain('"transcript_path":""')
  expect(run).toContain(`"cwd":"${R}"`)
})

test("/iamlazy-review is not /iamlazy", async () => {
  await h["command.execute.before"]({ command: "iamlazy-review", sessionID: "ses_review", arguments: "" }, { parts: [] })
  expect(existsSync(runFile("ses_review"))).toBe(false)
})

test("chat.message asks open-run.sh for the run's state; system.transform injects it for that session only", async () => {
  await chat(h, S, "iamlazy", "seguimos")
  const sys = { system: ["base"] }
  await h["experimental.chat.system.transform"]({ sessionID: S, model: {} }, sys)
  expect(sys.system.length).toBe(2)
  expect(sys.system[1]).toMatch(/^iamlazy: corrida activa en /)
  const other = { system: [] as string[] }
  await h["experimental.chat.system.transform"]({ sessionID: "ses_other", model: {} }, other)
  expect(other.system.length).toBe(0)
})

test("task with a foreign subagent_type is refused with guard-agent.sh's own reason", async () => {
  await expect(before(h, S, "task", { description: "map", subagent_type: "explore", prompt: "x" })).rejects.toThrow(
    /the Critic is the only sub-agent/,
  )
})

test("task spawning iamlazy-critic passes", async () => {
  await expect(before(h, S, "task", { description: "review", subagent_type: "iamlazy-critic", prompt: "x" })).resolves.toBeUndefined()
})

test("a child session's events are attributed to the parent's run", async () => {
  await created(h, C, S)
  await expect(before(h, C, "task", { description: "n", subagent_type: "explore", prompt: "x" })).rejects.toThrow(/only sub-agent/)
})

test("the Critic's bash cannot write; its reads pass; the main thread's bash is untouched", async () => {
  await chat(h, C, "iamlazy-critic", "review this")
  await expect(before(h, C, "bash", { command: "echo x > f.txt", description: "d" })).rejects.toThrow(/read-only/)
  await expect(before(h, C, "bash", { command: "rg -n foo src", description: "d" })).resolves.toBeUndefined()
  await expect(before(h, S, "bash", { command: "echo x > f.txt", description: "d" })).resolves.toBeUndefined()
})

test("writing the contract pins project_root and base_ref", async () => {
  mkdirSync(join(R, ".iamlazy"), { recursive: true })
  writeFileSync(join(R, ".iamlazy", "contract.md"), "# Task\nProbar el adaptador\n\n## Scope\n- *.ts\n\n## Groups\n- [x] g1 — `true`\n")
  await after(h, S, "write", { filePath: join(R, ".iamlazy", "contract.md"), content: "" })
  const run = read(runFile(S))
  expect(run).toContain(`"project_root":"${R}"`)
  expect(run).toMatch(/"base_ref":"[0-9a-f]{40}"/)
})

test("edit and write land in the journal as Edit/Write with the relative path", async () => {
  writeFileSync(join(R, "a.ts"), "export const a = 1\n")
  await after(h, S, "edit", { filePath: join(R, "a.ts"), oldString: "", newString: "" })
  await after(h, S, "write", { filePath: join(R, "b.ts"), content: "" })
  const j = read(join(R, ".iamlazy", "journal.md"))
  expect(j).toMatch(/ Edit a\.ts$/m)
  expect(j).toMatch(/ Write b\.ts$/m)
})

test("completed assistant messages, main thread and child, accumulate once each into the cost sidecar", async () => {
  await assistant(h, S, "msg_1", 0.5)
  await assistant(h, S, "msg_1", 0.5)
  await assistant(h, C, "msg_2", 0.25)
  await assistant(h, S, "msg_3", 9, false)
  const cost = read(sidecar(S, "cost"))
  expect(cost).toContain("cost_micro=750000\n")
  expect(cost).toContain("tokens_output=40\n")
  expect(cost).toContain("tokens_cache_write=80\n")
  expect(cost).toContain("tokens_cache_read=60\n")
  // The model rides along with the cost, as `providerID/modelID`. This host
  // leaves no Claude-style transcript, so the message it prices is the only
  // place its model is ever visible -- and the same de-duplication applies:
  // two completed messages here, not the four events that were sent.
  expect(cost).toContain("models=p/m:2\n")
  expect(existsSync(sidecar(C, "cost"))).toBe(false)
})

test("the Critic returning is SubagentStop: critic_done and the findings tally", async () => {
  await after(
    h,
    S,
    "task",
    { description: "review", subagent_type: "iamlazy-critic", prompt: "x" },
    { title: "", output: "Revisión.\n\nfindings: 0/1/2/0\n", metadata: { sessionId: C } },
  )
  expect(read(runFile(S))).toContain('"critic_done":1')
  expect(read(sidecar(S, "findings"))).toBe("0/1/2/0")
})

test("a background task is not a review that returned", async () => {
  const R2 = mkrepo()
  const h2 = await plugin(R2)
  const S2 = "ses_background"
  await open(h2, S2, "x")
  await after(
    h2,
    S2,
    "task",
    { description: "r", subagent_type: "iamlazy-critic", prompt: "x", background: true },
    { title: "", output: "task started in background", metadata: {} },
  )
  expect(read(runFile(S2))).not.toContain("critic_done")
})

test("the child session going idle is not the run's Stop", async () => {
  await idle(h, C)
  expect(existsSync(runFile(S))).toBe(true)
})

test("session.idle with the CLOSE banner flushes: one log line with host, cost, findings, stage; the run is cleared", async () => {
  await assistant(h, S, "msg_4", 0.1)
  await text(h, S, "msg_4", "prt_1", "Listo.")
  await text(h, S, "msg_4", "prt_2", "── CIERRE · m · high ──\nEntregado.")
  await idle(h, S)
  expect(existsSync(runFile(S))).toBe(false)
  expect(existsSync(sidecar(S, "cost"))).toBe(false)
  const line = logLine(S)
  expect(line).toContain('"host":"opencode"')
  expect(line).toContain('"cost_usd":0.8500')
  expect(line).toContain('"critic_findings":"0/1/2/0"')
  expect(line).toContain('"close_detected_via":"contract"')
  expect(line).toContain('"files_changed":1')
  expect(line).toContain('"stage_reached":"CIERRE"')
  expect(line).toContain('"outcome":"flushed"')
})

test("the scope gate speaks: a blocked close is fed back to the model once, the human is toasted, the run stays open", async () => {
  const R3 = mkrepo()
  const h3 = await plugin(R3)
  const S3 = "ses_gate"
  await open(h3, S3, "x")
  mkdirSync(join(R3, ".iamlazy"), { recursive: true })
  writeFileSync(join(R3, ".iamlazy", "contract.md"), "# Task\nT\n\n## Scope\n- src/*\n\n## Groups\n- [x] g1 — `true`\n")
  await after(h3, S3, "write", { filePath: join(R3, ".iamlazy", "contract.md"), content: "" })
  writeFileSync(join(R3, "fuera.txt"), "x\n")
  await after(
    h3,
    S3,
    "task",
    { description: "r", subagent_type: "iamlazy-critic", prompt: "x" },
    { title: "", output: "findings: 0/0/0/0", metadata: {} },
  )
  await assistant(h3, S3, "msg_g", 0.01)
  await text(h3, S3, "msg_g", "prt_g", "── CIERRE · m · high ──")
  const n = calls.prompts.length
  await idle(h3, S3)
  expect(existsSync(runFile(S3))).toBe(true)
  expect(calls.prompts.length).toBe(n + 1)
  const p = calls.prompts[n]
  expect(p.path.id).toBe(S3)
  expect(p.body.parts[0].text).toContain("fuera.txt")
  expect(calls.toasts.at(-1)?.body.message).toContain("fuera.txt")
  await idle(h3, S3)
  expect(calls.prompts.length).toBe(n + 1)
  expect(existsSync(runFile(S3))).toBe(true)
})

test("dispose logs every run this plugin opened as abandoned", async () => {
  const R4 = mkrepo()
  const h4 = await plugin(R4)
  const S4 = "ses_dispose"
  await open(h4, S4, "x")
  await h4.dispose()
  expect(existsSync(runFile(S4))).toBe(false)
  expect(logLine(S4)).toContain('"outcome":"abandoned"')
})

test("session.deleted is SessionEnd", async () => {
  const R5 = mkrepo()
  const h5 = await plugin(R5)
  const S5 = "ses_deleted"
  await open(h5, S5, "x")
  await h5.event({ event: { type: "session.deleted", properties: { info: session(S5) } } })
  expect(existsSync(runFile(S5))).toBe(false)
  expect(logLine(S5)).toContain('"outcome":"abandoned"')
})
