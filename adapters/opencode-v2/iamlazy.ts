// iamlazy-managed
// OpenCode V2 adapter, targeting the native @opencode/plugin API (v2.0.x).
// Layer 0 still lives in ~/.config/opencode/iamlazy-hooks/; this file is only
// the translator between OpenCode's V2 events and that Layer 0's payload
// shape. adapters/opencode/iamlazy.ts is the SEPARATE V1 adapter
// (@opencode-ai/plugin) -- the two hosts are not compatible and this file does
// not replace that one.
//
// This file is a real ES module with a REAL runtime dependency on
// @opencode/plugin (V1's adapter only needed `import type`, so it ran as a
// loose, dependency-free .ts file). V2's daemon cannot resolve that import
// when it dynamically loads a local plugin file or directory -- confirmed
// against the real v2.0.1 binary: "Cannot find package '@opencode/plugin'"
// even with the package correctly installed in an ancestor node_modules.
// build.sh in this directory bundles this file (and its whole dependency
// tree) into one dependency-free .js file with `bun build --target=bun`,
// which IS loadable, because at that point nothing needs resolving anymore.
// See README.md in this directory for the full story and the deploy steps.
import { Plugin } from "@opencode/plugin"

type Payload = Record<string, unknown>
type HookResult = { code: number; stdout: string; stderr: string }
type Decision = {
  decision?: string
  reason?: string
  systemMessage?: string
  hookSpecificOutput?: { permissionDecision?: string; permissionDecisionReason?: string }
}

type ModelRef = { providerID: string; id: string; variant?: string }
type UsageTotals = { cost: number; output: number; cacheWrite: number; cacheRead: number }

export default Plugin.define({
  id: "iamlazy",
  async setup(ctx) {
    const home = process.env.HOME ?? ""
    const hooksDir = `${home}/.config/opencode/iamlazy-hooks`
    const fallbackCwd = ctx.location.directory

    // Per-session bookkeeping. In V1 these were keyed off the session passed to
    // each hook; in V2 we derive them from events and request hooks.
    const parentOf = new Map<string, string>()
    const agentOf = new Map<string, string>()
    const modelOf = new Map<string, string>()
    const cwdOf = new Map<string, string>()
    const context = new Map<string, string>()
    const opened = new Set<string>()
    const continued = new Set<string>()
    // Baseline for turning V2's cumulative session.usage.updated totals into
    // per-event deltas -- see the HostCost handling below.
    const usageOf = new Map<string, UsageTotals>()

    const root = (sid: string): string => {
      let s = sid
      for (let hops = 0; parentOf.has(s) && hops < 16; hops++) s = parentOf.get(s) as string
      return s
    }

    const cwdFor = (sid: string): string => cwdOf.get(sid) ?? fallbackCwd

    const runHook = async (hook: string, payload: Payload): Promise<HookResult> => {
      const script = `${hooksDir}/${hook}`
      const sessionID = (payload.session_id as string) ?? ""
      const body = JSON.stringify({
        ...payload,
        host: "opencode",
        transcript_path: "",
        cwd: cwdFor(sessionID),
      })
      const proc = Bun.spawn([script], {
        stdin: new Response(body),
        stdout: "pipe",
        stderr: "pipe",
        env: { ...process.env, HOME: home },
      })
      const [stdout, stderr] = await Promise.all([
        new Response(proc.stdout).text(),
        new Response(proc.stderr).text(),
      ])
      const exitCode = await proc.exited
      return { code: exitCode, stdout, stderr }
    }

    const decisionOf = (stdout: string): Decision | null => {
      for (const line of stdout.split("\n")) {
        try {
          const parsed: unknown = JSON.parse(line)
          if (parsed && typeof parsed === "object") return parsed as Decision
        } catch {}
      }
      return null
    }

    // Only "deny" throws. guard-agent.sh now emits "ask" for the Critic; this
    // host has no interactive permission prompt, so the spawn proceeds exactly
    // like the plain allow it replaced.
    const refuse = (r: HookResult): void => {
      const out = decisionOf(r.stdout)?.hookSpecificOutput
      if (out?.permissionDecision === "deny") throw new Error(out.permissionDecisionReason ?? "iamlazy: refused")
    }

    const forget = (sid: string): void => {
      parentOf.delete(sid)
      agentOf.delete(sid)
      modelOf.delete(sid)
      cwdOf.delete(sid)
      context.delete(sid)
      opened.delete(sid)
      continued.delete(sid)
      usageOf.delete(sid)
    }

    // V1 command.execute.before has no direct V2 equivalent. Because /iamlazy
    // needs to run Layer 0 code before the agent is switched, the plugin owns
    // the command definition here: OpenCode's own commands/iamlazy.md must
    // NOT also be installed on this host, or the command is defined twice.
    await ctx.command.transform((editor) => {
      editor.add({
        name: "iamlazy",
        description: "iamlazy — full development harness (5 artifacts, one thread)",
        execute: async ({ sessionID, prompt, delivery }) => {
          const sid = root(sessionID)
          opened.add(sid)
          const promptText = prompt.text ?? ""
          const fullPrompt = promptText ? `/iamlazy ${promptText}` : "/iamlazy"
          const r = await runHook("open-run.sh", {
            hook_event_name: "UserPromptSubmit",
            session_id: sid,
            prompt: fullPrompt,
          })
          if (r.code === 2) throw new Error(r.stderr.trim() || "iamlazy: refused to start")
          await ctx.session.switchAgent({ sessionID, agent: "iamlazy" })
          // Forward the whole prompt -- files/agents/skills included, not
          // just its text. SessionApi.prompt's real input is flat
          // (sessionID, text, files?, agents?, skills?, delivery?), confirmed
          // against the installed @opencode/client types, so the spread
          // lines up field-for-field; forwarding only `text` silently drops
          // every attachment.
          await ctx.session.prompt({ sessionID, ...prompt, delivery })
        },
      })
    })

    // V1 chat.message -> V2 session.hook("prompt"). Fires for every admitted
    // user prompt. During an open run this is how the model is told what the
    // harness currently knows; outside a run it is inert.
    await ctx.session.hook("prompt", async (event) => {
      const sid = event.sessionID
      if (parentOf.has(sid)) return
      const r = await runHook("open-run.sh", {
        hook_event_name: "UserPromptSubmit",
        session_id: sid,
        prompt: event.prompt.text,
      })
      const line = r.stdout.trim()
      if (line) context.set(sid, line)
      else context.delete(sid)
    })

    // V1 experimental.chat.system.transform -> V2 session.hook("context").
    // Also tracks the active agent/model per session because the prompt hook
    // no longer carries that metadata.
    await ctx.session.hook("context", async (event) => {
      agentOf.set(event.sessionID, event.agent)
      if (event.model) {
        const m = event.model as ModelRef
        modelOf.set(event.sessionID, m.providerID && m.id ? `${m.providerID}/${m.id}` : "")
      }
      const line = context.get(event.sessionID)
      if (line) event.system.push({ type: "text", text: line })
    })

    // V1 tool.execute.before -> V2 ctx.tool.hook("execute.before"). Layer 0's
    // hooks are written against Claude Code's tool identity/shape and expect
    // it verbatim: tool_name in {Agent,Task}, and a subagent_type field. V2
    // names the tool "subagent" and carries its target as `agent` instead --
    // both normalized here, once, rather than teaching guard-agent.sh a
    // second tool vocabulary. Before this fix, guard-agent.sh saw
    // tool_name="Subagent" (outside its Agent|Task whitelist) and allowed
    // every call through unexamined -- the one-writer guard was a no-op.
    await ctx.tool.hook("execute.before", async (event) => {
      const sid = root(event.sessionID)
      const tool = event.tool

      if (tool === "subagent" || tool === "task") {
        const input = (event.input ?? {}) as { agent?: string; subagent_type?: string }
        refuse(
          await runHook("guard-agent.sh", {
            hook_event_name: "PreToolUse",
            session_id: sid,
            tool_name: "Agent",
            tool_input: { ...input, subagent_type: input.agent ?? input.subagent_type },
          }),
        )
      } else if (tool === "shell" || tool === "bash") {
        refuse(
          await runHook("guard-critic-bash.sh", {
            hook_event_name: "PreToolUse",
            session_id: sid,
            agent_type: event.agent,
            tool_name: "Bash",
            tool_input: event.input,
          }),
        )
      }
    })

    // V1 tool.execute.after -> V2 ctx.tool.hook("execute.after").
    await ctx.tool.hook("execute.after", async (event) => {
      const sid = root(event.sessionID)
      const tool = event.tool
      const input = (event.input ?? {}) as {
        path?: string
        filePath?: string
        file_path?: string
        agent?: string
        subagent_type?: string
        background?: boolean
      }
      // V2's edit/write tools carry the target as `path`; the old
      // filePath/file_path names (Claude Code's shape) are kept as a
      // fallback only. Before this fix `path` was never read, so every V2
      // edit/write silently skipped the journal and contract-root tracking.
      const filePath = input.path ?? input.filePath ?? input.file_path
      const subagentType = input.agent ?? input.subagent_type

      if ((tool === "edit" || tool === "write") && filePath && event.status === "completed") {
        await runHook("track-edit.sh", {
          hook_event_name: "PostToolUse",
          session_id: sid,
          tool_name: tool === "edit" ? "Edit" : "Write",
          tool_input: { file_path: filePath },
        })
      } else if ((tool === "subagent" || tool === "task") && subagentType && !input.background) {
        if (event.status === "completed") {
          const result = event.result as
            | {
                metadata?: { sessionId?: string; sessionID?: string }
                output?: string
                content?: string | ReadonlyArray<{ type?: string; text?: string }>
              }
            | undefined
          let output = ""
          if (typeof result?.output === "string") {
            output = result.output
          } else if (typeof result?.content === "string") {
            output = result.content
          } else if (Array.isArray(result?.content)) {
            output = result.content
              .map((c) => (c.type === "text" && typeof c.text === "string" ? c.text : ""))
              .join("\n")
          }
          await runHook("subagent-done.sh", {
            hook_event_name: "SubagentStop",
            session_id: sid,
            agent_id: result?.metadata?.sessionId ?? result?.metadata?.sessionID ?? "",
            agent_type: subagentType,
            last_assistant_message: output,
          })
        }
      }
    })

    // V1 event/dispose -> V2 ctx.event.subscribe() + cleanup function.
    const controller = new AbortController()
    const eventTask = (async () => {
      for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
        try {
          if (event.type === "session.created") {
            const data = event.data as {
              sessionID: string
              parentID?: string
              agent?: string
              location?: { directory?: string }
            }
            if (data.parentID) parentOf.set(data.sessionID, data.parentID)
            if (data.agent) agentOf.set(data.sessionID, data.agent)
            if (data.location?.directory) cwdOf.set(data.sessionID, data.location.directory)
            continue
          }

          if (event.type === "session.deleted") {
            const data = event.data as { sessionID: string }
            if (!parentOf.has(data.sessionID)) {
              await runHook("end-run.sh", {
                hook_event_name: "SessionEnd",
                session_id: data.sessionID,
              })
            }
            forget(data.sessionID)
            continue
          }

          if (event.type === "session.usage.updated") {
            const data = event.data as {
              sessionID: string
              cost: number
              tokens: { output: number; cache: { write: number; read: number } }
            }
            // The client replaces session.info.cost/tokens with running
            // SESSION TOTALS on every update, not per-update deltas (verified
            // in the installed client and reproduced against the real
            // v2.0.1 binary). host-cost.sh's contract is purely additive --
            // "De-duplication ... is the adapter's job, because only it sees
            // ids" -- so forwarding each total verbatim summed $1 then $3
            // into a recorded $4. Track the last total per session and
            // forward only what changed since. This also fixes the "second
            // run in the same session" case for free: the baseline is never
            // reset at run-open, so it already reflects the end of the
            // previous run.
            const prev = usageOf.get(data.sessionID) ?? { cost: 0, output: 0, cacheWrite: 0, cacheRead: 0 }
            const cur: UsageTotals = {
              cost: data.cost,
              output: data.tokens.output,
              cacheWrite: data.tokens.cache.write,
              cacheRead: data.tokens.cache.read,
            }
            usageOf.set(data.sessionID, cur)
            const deltaCost = Math.max(0, cur.cost - prev.cost)
            const deltaOutput = Math.max(0, cur.output - prev.output)
            const deltaCacheWrite = Math.max(0, cur.cacheWrite - prev.cacheWrite)
            const deltaCacheRead = Math.max(0, cur.cacheRead - prev.cacheRead)
            if (deltaCost || deltaOutput || deltaCacheWrite || deltaCacheRead) {
              await runHook("host-cost.sh", {
                hook_event_name: "HostCost",
                session_id: root(data.sessionID),
                cost_micro: Math.round(deltaCost * 1_000_000),
                tokens_output: deltaOutput,
                tokens_cache_write: deltaCacheWrite,
                tokens_cache_read: deltaCacheRead,
                // The ORIGINATING session's own model, not the root's: the
                // Critic prices its own messages on its own (child) session,
                // and attributing them to the root lookup mislabeled the
                // run's model tally with whichever model the root happened
                // to be on.
                model: modelOf.get(data.sessionID) ?? modelOf.get(root(data.sessionID)) ?? "",
              })
            }
            continue
          }

          // V1's Stop hook fires whenever the assistant stops talking,
          // regardless of how the turn ended. "session.idle"/"session.status"
          // (guessed from the V1 vocabulary) do not exist on the real v2.0.1
          // event bus -- confirmed by capturing its raw SSE stream, which
          // only ever emits session.execution.{started,succeeded,failed,
          // interrupted}. Without this fix the run NEVER flushes: it opens,
          // tracks edits and the Critic correctly, and then sits in
          // ~/.iamlazy/active forever because the idle branch never once
          // matched a real event type.
          const isIdle =
            event.type === "session.execution.succeeded" ||
            event.type === "session.execution.failed" ||
            event.type === "session.execution.interrupted"
          if (isIdle) {
            const data = event.data as { sessionID: string }
            const sid = root(data.sessionID)
            if (parentOf.has(data.sessionID)) continue

            // V1 accumulated assistant text parts from message.part.updated.
            // V2 does not expose those events directly, so we read the last
            // assistant message from the session context at idle time.
            let text = ""
            try {
              const messages = await ctx.session.context({ sessionID: sid })
              for (let i = messages.length - 1; i >= 0; i--) {
                const msg = messages[i] as {
                  type?: string
                  role?: string
                  content?:
                    | string
                    | ReadonlyArray<{ type?: string; text?: string }>
                }
                if (msg.type === "assistant" || msg.role === "assistant") {
                  if (Array.isArray(msg.content)) {
                    text = msg.content
                      .map((c) =>
                        c.type === "text" && typeof c.text === "string" ? c.text : "",
                      )
                      .join("\n")
                  } else if (typeof msg.content === "string") {
                    text = msg.content
                  }
                  break
                }
              }
            } catch {
              text = ""
            }

            const r = await runHook("flush-run.sh", {
              hook_event_name: "Stop",
              session_id: sid,
              stop_hook_active: continued.delete(sid),
              last_assistant_message: text,
            })
            if (r.code !== 2) continue

            const block = decisionOf(r.stdout)
            const reason = block?.reason ?? r.stderr.trim()
            if (!reason) continue

            continued.add(sid)
            if (block?.systemMessage) {
              // V2 server plugins have no TUI toast API; log the warning.
              console.log(`[iamlazy] ${block.systemMessage}`)
            }
            await ctx.session.synthetic({ sessionID: sid, text: reason })
          }
        } catch (err) {
          // A crashed event handler should not kill the plugin. Log and keep
          // going so the run can still be closed on dispose if needed.
          console.error("[iamlazy] event handler error:", err)
        }
      }
    })()

    // Returning a cleanup function replaces V1 dispose().
    return async () => {
      controller.abort()
      try {
        await eventTask
      } catch {
        // Expected when the subscription is aborted.
      }
      for (const sid of opened) {
        await runHook("end-run.sh", {
          hook_event_name: "SessionEnd",
          session_id: sid,
        })
      }
      opened.clear()
    }
  },
})
