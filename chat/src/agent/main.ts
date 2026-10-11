import { createInterface } from "node:readline";
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { query, type Options, type McpServerConfig, type PermissionResult, type SDKMessage } from "@anthropic-ai/claude-agent-sdk";
import { AGENT_TOOLS, AUTO_ALLOWED_TOOLS, describeToolCall, needsPermission, type AgentConfig, type AgentToHelper, type HelperToAgent } from "./protocol";
import { listeningServer } from "./listeningTools";

/**
 * TBD's default agent process (C24): the Claude Agent SDK harness with the
 * user's own model key, its own state directory (never ~/.claude), no user or
 * project settings, harness-local tools (Companion timeline, Listening) and
 * Teal Brick apps through the local relay. Every built-in tool that changes
 * this Mac asks the person through TBD's consent card first.
 *
 * Started by the Chat helper with an allow-listed environment: the model key
 * and nothing that belongs to the person's Portal session.
 */

const out = (m: AgentToHelper) => process.stdout.write(`${JSON.stringify(m)}\n`);
console.log = console.info = console.debug = (...a: unknown[]) => console.error(...a);

let config: AgentConfig | null = null;
const turns = new Map<string, AbortController>();
const permissions = new Map<string, (r: { allow: boolean; message?: string }) => void>();
let nextReq = 0;

function mcpServers(c: AgentConfig): Record<string, McpServerConfig> {
  const servers: Record<string, McpServerConfig> = {};
  if (c.companionCli) servers.companion = { type: "stdio", command: c.companionCli, args: ["mcp"], env: { HOME: process.env.HOME ?? "" } };
  if (c.listeningCli) servers.listening = listeningServer(c.listeningCli);
  if (c.relay) servers.tealbrick = { type: "stdio", command: c.relay.command, args: c.relay.args, env: c.relay.env };
  return servers;
}

function options(c: AgentConfig, id: string, abort: AbortController, sessionId?: string): Options {
  return {
    abortController: abort,
    model: c.model.model,
    cwd: c.cwd,
    resume: sessionId,
    includePartialMessages: true,
    settingSources: [],
    strictMcpConfig: true,
    tools: AGENT_TOOLS,
    allowedTools: AUTO_ALLOWED_TOOLS,
    permissionMode: "default",
    mcpServers: mcpServers(c),
    pathToClaudeCodeExecutable: c.claudeExecutable,
    systemPrompt: { type: "preset", preset: "claude_code", append: [
      "You are TBD, the person's default Teal Brick agent, running on their Mac.",
      "You can read their screen-activity timeline (companion tools) and their transcripts and meetings (listening tools).",
      "Teal Brick apps (memory, connected accounts) are available through the tealbrick tools when connected; the workspace bridge decides what you may do there.",
      c.systemAppend ?? "",
    ].join("\n") },
    env: {
      // The harness's own state, isolated from the person's Claude setup.
      CLAUDE_CONFIG_DIR: join(c.stateDir, "claude"),
      HOME: process.env.HOME,
      PATH: "/usr/bin:/bin:/usr/sbin:/sbin",
      ANTHROPIC_API_KEY: process.env.ANTHROPIC_API_KEY,
      ...(c.model.baseUrl ? { ANTHROPIC_BASE_URL: c.model.baseUrl } : {}),
    },
    canUseTool: async (tool, input, { signal }): Promise<PermissionResult> => {
      if (!needsPermission(tool)) return { behavior: "allow", updatedInput: input };
      const reqId = `p${++nextReq}`;
      out({ type: "permission_request", id, reqId, tool, detail: describeToolCall(tool, input) });
      const decision = await new Promise<{ allow: boolean; message?: string }>((resolve) => {
        permissions.set(reqId, resolve);
        signal.addEventListener("abort", () => resolve({ allow: false, message: "Turn stopped." }), { once: true });
      });
      permissions.delete(reqId);
      return decision.allow ? { behavior: "allow", updatedInput: input } : { behavior: "deny", message: decision.message ?? "The person declined this action." };
    },
  };
}

/** Map SDK messages to the Chat's event vocabulary. */
function relay(id: string, m: SDKMessage, state: { text: string }): void {
  if (m.type === "stream_event" && m.parent_tool_use_id === null) {
    const e = m.event;
    if (e.type === "content_block_start" && e.content_block.type === "tool_use") {
      out({ type: "event", id, event: { kind: "activity", label: activityLabel(e.content_block.name) } });
      // Narration before a tool call is not the answer.
      if (state.text) { state.text = ""; out({ type: "event", id, event: { kind: "reset" } }); }
    } else if (e.type === "content_block_delta" && e.delta.type === "text_delta") {
      state.text += e.delta.text;
      out({ type: "event", id, event: { kind: "delta", text: e.delta.text } });
    } else if (e.type === "message_start") {
      out({ type: "event", id, event: { kind: "activity", label: "Thinking" } });
    }
  } else if (m.type === "system" && m.subtype === "init") {
    out({ type: "event", id, event: { kind: "session", sessionId: m.session_id } });
  }
}

function activityLabel(tool: string): string {
  if (tool.startsWith("mcp__companion__")) return "Reading your timeline";
  if (tool.startsWith("mcp__listening__")) return "Reading your transcripts";
  if (tool.startsWith("mcp__tealbrick__")) return "Using a Teal Brick app";
  return { Read: "Reading a file", Glob: "Finding files", Grep: "Searching files", Edit: "Editing a file", Write: "Writing a file", Bash: "Running a command", WebFetch: "Fetching a page", WebSearch: "Searching the web" }[tool] ?? `Using ${tool}`;
}

async function runTurn(id: string, text: string, sessionId?: string): Promise<void> {
  if (!config) { out({ type: "error", id, message: "Agent is not initialised." }); return; }
  const abort = new AbortController();
  turns.set(id, abort);
  const state = { text: "" };
  let session = sessionId ?? "";
  try {
    for await (const m of query({ prompt: text, options: options(config, id, abort, sessionId) })) {
      if ("session_id" in m && typeof m.session_id === "string") session = m.session_id;
      relay(id, m, state);
      if (m.type === "result") {
        out({ type: "event", id, event: { kind: "activity", label: null } });
        if (m.subtype === "success" && !m.is_error) out({ type: "done", id, sessionId: session, reply: m.result });
        else out({ type: "error", id, message: m.subtype === "success" ? m.result : `The agent stopped (${m.subtype}).` });
        return;
      }
    }
    out({ type: "error", id, message: abort.signal.aborted ? "Stopped." : "The agent ended without an answer." });
  } catch (error) {
    out({ type: "error", id, message: abort.signal.aborted ? "Stopped." : error instanceof Error ? error.message : String(error) });
  } finally {
    turns.delete(id);
  }
}

const lines = createInterface({ input: process.stdin });
lines.on("line", (line) => {
  let m: HelperToAgent;
  try { m = JSON.parse(line) as HelperToAgent; } catch { return; }
  switch (m.type) {
    case "init":
      config = m.config;
      mkdirSync(join(config.stateDir, "claude"), { recursive: true, mode: 0o700 });
      out({ type: "ready" });
      break;
    case "turn": void runTurn(m.id, m.text, m.sessionId); break;
    case "cancel": turns.get(m.id)?.abort(); break;
    case "permission": permissions.get(m.reqId)?.({ allow: m.allow, message: m.message }); break;
    case "shutdown": for (const t of turns.values()) t.abort(); setTimeout(() => process.exit(0), 300); break;
  }
});
lines.on("close", () => process.exit(0));
