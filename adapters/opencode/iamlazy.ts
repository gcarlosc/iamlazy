// iamlazy-managed
import type { Plugin } from "@opencode-ai/plugin"

type Payload = Record<string, unknown>
type HookResult = { code: number; stdout: string; stderr: string }
type Decision = {
  decision?: string
  reason?: string
  systemMessage?: string
  hookSpecificOutput?: { permissionDecision?: string; permissionDecisionReason?: string }
}

// Every export of this module must be a FUNCTION. OpenCode walks the module's
// exports and calls each one as a plugin: a `const id = "iamlazy"` alongside
// this made it refuse the whole file with `Plugin export is not a function`,
// logged to ~/.local/share/opencode/log/opencode.log and nowhere else -- so
// `opencode debug info` still listed the plugin, because it lists what it
// DISCOVERED, not what loaded. Verified 2026-09-06 by a real run in which
// Layer 1 worked perfectly and Layer 0 wrote nothing at all.
export const server: Plugin = async ({ $, client, directory }) => {
  const home = process.env.HOME ?? ""
  const hooksDir = `${home}/.config/opencode/iamlazy-hooks`

  const parentOf = new Map<string, string>()
  const agentOf = new Map<string, string>()
  const context = new Map<string, string>()
  const opened = new Set<string>()
  const costed = new Set<string>()
  const turnOf = new Map<string, string>()
  const turnText = new Map<string, Map<string, string>>()
  const continued = new Set<string>()

  const root = (sid: string): string => {
    let s = sid
    for (let hops = 0; parentOf.has(s) && hops < 16; hops++) s = parentOf.get(s) as string
    return s
  }

  const run = async (hook: string, payload: Payload): Promise<HookResult> => {
    const script = `${hooksDir}/${hook}`
    const body = JSON.stringify({ ...payload, host: "opencode", transcript_path: "", cwd: directory })
    const r = await $`${script} < ${new Response(body)}`
      .env({ ...process.env, HOME: home })
      .quiet()
      .nothrow()
    return { code: r.exitCode, stdout: r.stdout.toString(), stderr: r.stderr.toString() }
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

  // Only "deny" throws. guard-agent.sh now emits "ask" instead of a bare
  // allow for the Critic (2026-09-11), and this host has no interactive
  // permission prompt to route it through -- so it falls through here and
  // the spawn proceeds, exactly like the plain allow it replaced. Deliberate
  // degrade, not a gap: "the prompt never promises what its host does not
  // enforce" (PROJECT.md), and OpenCode's own guarantees text never claims
  // the Critic asks.
  const refuse = (r: HookResult): void => {
    const out = decisionOf(r.stdout)?.hookSpecificOutput
    if (out?.permissionDecision === "deny") throw new Error(out.permissionDecisionReason ?? "iamlazy: refused")
  }

  const forget = (sid: string): void => {
    parentOf.delete(sid)
    agentOf.delete(sid)
    context.delete(sid)
    opened.delete(sid)
    turnOf.delete(sid)
    turnText.delete(sid)
    continued.delete(sid)
  }

  return {
    "command.execute.before": async (input) => {
      if (input.command.replace(/^\//, "") !== "iamlazy") return
      const sid = root(input.sessionID)
      opened.add(sid)
      const prompt = input.arguments ? `/iamlazy ${input.arguments}` : "/iamlazy"
      const r = await run("open-run.sh", { hook_event_name: "UserPromptSubmit", session_id: sid, prompt })
      if (r.code === 2) throw new Error(r.stderr.trim() || "iamlazy: refused to start")
    },

    "chat.message": async (input, output) => {
      if (input.agent) agentOf.set(input.sessionID, input.agent)
      if (parentOf.has(input.sessionID)) return
      const prompt = output.parts.flatMap((p) => (p.type === "text" ? [p.text] : [])).join("\n")
      const r = await run("open-run.sh", { hook_event_name: "UserPromptSubmit", session_id: input.sessionID, prompt })
      const line = r.stdout.trim()
      if (line) context.set(input.sessionID, line)
      else context.delete(input.sessionID)
    },

    "experimental.chat.system.transform": async (input, output) => {
      const line = input.sessionID ? context.get(input.sessionID) : undefined
      if (line) output.system.push(line)
    },

    "tool.execute.before": async (input, output) => {
      const sid = root(input.sessionID)
      if (input.tool === "task") {
        refuse(
          await run("guard-agent.sh", {
            hook_event_name: "PreToolUse",
            session_id: sid,
            tool_name: "Agent",
            tool_input: output.args,
          }),
        )
      } else if (input.tool === "bash") {
        refuse(
          await run("guard-critic-bash.sh", {
            hook_event_name: "PreToolUse",
            session_id: sid,
            agent_type: agentOf.get(input.sessionID) ?? "",
            tool_name: "Bash",
            tool_input: output.args,
          }),
        )
      }
    },

    "tool.execute.after": async (input, output) => {
      const sid = root(input.sessionID)
      const args = (input.args ?? {}) as { filePath?: string; subagent_type?: string; background?: boolean }
      if ((input.tool === "edit" || input.tool === "write") && args.filePath) {
        await run("track-edit.sh", {
          hook_event_name: "PostToolUse",
          session_id: sid,
          tool_name: input.tool === "edit" ? "Edit" : "Write",
          tool_input: { file_path: args.filePath },
        })
      } else if (input.tool === "task" && args.subagent_type && !args.background) {
        const meta = (output.metadata ?? {}) as { sessionId?: string }
        await run("subagent-done.sh", {
          hook_event_name: "SubagentStop",
          session_id: sid,
          agent_id: meta.sessionId ?? "",
          agent_type: args.subagent_type,
          last_assistant_message: output.output,
        })
      }
    },

    event: async ({ event }) => {
      if (event.type === "session.created") {
        const info = event.properties.info
        if (info.parentID) parentOf.set(info.id, info.parentID)
        return
      }
      if (event.type === "session.deleted") {
        const info = event.properties.info
        if (!parentOf.has(info.id)) await run("end-run.sh", { hook_event_name: "SessionEnd", session_id: info.id })
        forget(info.id)
        return
      }
      if (event.type === "message.updated") {
        const info = event.properties.info
        if (info.role !== "assistant") return
        const agent = (info as { agent?: string }).agent
        if (agent) agentOf.set(info.sessionID, agent)
        if (turnOf.get(info.sessionID) !== info.id) {
          turnOf.set(info.sessionID, info.id)
          turnText.set(info.sessionID, new Map())
        }
        if (!info.time.completed || costed.has(info.id)) return
        costed.add(info.id)
        // `providerID/modelID` is the form `opencode models` prints and
        // `models.conf` is written in, so the log reads in the same vocabulary
        // the config does. Both fields are on the real assistant message
        // (verified against the SQLite store, 2026-09-11); if either is absent
        // the model is sent empty and the hook simply records nothing.
        const m = info as { providerID?: string; modelID?: string }
        await run("host-cost.sh", {
          hook_event_name: "HostCost",
          session_id: root(info.sessionID),
          cost_micro: Math.round(info.cost * 1_000_000),
          tokens_output: info.tokens.output,
          tokens_cache_write: info.tokens.cache.write,
          tokens_cache_read: info.tokens.cache.read,
          model: m.providerID && m.modelID ? `${m.providerID}/${m.modelID}` : "",
        })
        return
      }
      if (event.type === "message.part.updated") {
        const part = event.properties.part
        if (part.type !== "text" || turnOf.get(part.sessionID) !== part.messageID) return
        turnText.get(part.sessionID)?.set(part.id, part.text)
        return
      }
      if (event.type === "session.idle") {
        const sid = event.properties.sessionID
        if (parentOf.has(sid)) return
        const text = [...(turnText.get(sid)?.values() ?? [])].join("\n")
        const r = await run("flush-run.sh", {
          hook_event_name: "Stop",
          session_id: sid,
          stop_hook_active: continued.delete(sid),
          last_assistant_message: text,
        })
        if (r.code !== 2) return
        const block = decisionOf(r.stdout)
        const reason = block?.reason ?? r.stderr.trim()
        if (!reason) return
        continued.add(sid)
        if (block?.systemMessage) {
          void client.tui
            .showToast({ body: { message: block.systemMessage, variant: "warning" } })
            .catch(() => undefined)
        }
        void client.session
          .promptAsync({ path: { id: sid }, body: { parts: [{ type: "text", text: reason, synthetic: true }] } })
          .catch(() => undefined)
      }
    },

    dispose: async () => {
      for (const sid of opened) await run("end-run.sh", { hook_event_name: "SessionEnd", session_id: sid })
      opened.clear()
    },
  }
}
