/**
 * The private stdio protocol between the TBD Chat helper (person side) and
 * TBD's default agent process (agent side). One JSON object per line.
 *
 * The agent process never receives the person credential (K3): its config
 * carries only the model route, its own MCP servers and local paths. The
 * Teal Brick relay authenticates as the AGENT (K4 handle via the signer
 * socket), never as the person.
 */

export interface AgentModel {
  /** Model id, e.g. from the "agent" route in Settings → Models. */
  model: string;
  /** Anthropic API base URL (default https://api.anthropic.com). */
  baseUrl?: string;
}

export interface AgentConfig {
  model: AgentModel;
  /** Default working folder for the agent's file tools. */
  cwd: string;
  /** Where the harness keeps its own state (never the user's ~/.claude). */
  stateDir: string;
  /** Path of the bundled Claude Code executable used by the Agent SDK. */
  claudeExecutable?: string;
  /** Harness-local tools (C5): Companion timeline MCP server and Listening CLI. */
  companionCli?: string;
  listeningCli?: string;
  /** Teal Brick apps through the local relay (stdio MCP child), once connected. */
  relay?: { command: string; args: string[]; env: Record<string, string> };
  /** Extra system prompt text (identity, workspace). */
  systemAppend?: string;
}

export type HelperToAgent =
  | { type: "init"; config: AgentConfig }
  | { type: "turn"; id: string; text: string; sessionId?: string }
  | { type: "cancel"; id: string }
  | { type: "permission"; reqId: string; allow: boolean; message?: string }
  | { type: "shutdown" };

export type AgentEvent =
  | { kind: "delta"; text: string }
  | { kind: "reset" }
  | { kind: "activity"; label: string | null }
  | { kind: "session"; sessionId: string };

export type AgentToHelper =
  | { type: "ready" }
  | { type: "event"; id: string; event: AgentEvent }
  | { type: "permission_request"; id: string; reqId: string; tool: string; detail: string }
  | { type: "done"; id: string; sessionId: string; reply: string }
  | { type: "error"; id?: string; message: string };

/** Tools a turn may use without asking: reads, harness-local reads, Teal Brick (the bridge decides). */
export const AUTO_ALLOWED_TOOLS = ["Read", "Glob", "Grep", "mcp__companion", "mcp__listening", "mcp__tealbrick"];
/** Built-in tools the default agent has at all; anything that changes this Mac asks the person first. */
export const AGENT_TOOLS = ["Read", "Glob", "Grep", "Edit", "Write", "Bash", "WebFetch", "WebSearch"];

/** Whether a tool call needs the person's click (C5: harness-local policy, shown by TBD). */
export function needsPermission(tool: string): boolean {
  if (tool.startsWith("mcp__companion__") || tool.startsWith("mcp__listening__") || tool.startsWith("mcp__tealbrick__")) return false;
  return !["Read", "Glob", "Grep"].includes(tool);
}

/** One line for the consent card: the exact effect, never "the agent wants a tool". */
export function describeToolCall(tool: string, input: Record<string, unknown>): string {
  const s = (v: unknown) => (typeof v === "string" ? v : JSON.stringify(v ?? ""));
  switch (tool) {
    case "Bash": return `Run: ${s(input.command)}`;
    case "Write": return `Write file ${s(input.file_path)}`;
    case "Edit": return `Edit file ${s(input.file_path)}`;
    case "WebFetch": return `Fetch ${s(input.url)}`;
    case "WebSearch": return `Search the web: ${s(input.query)}`;
    default: return `${tool} ${s(input).slice(0, 200)}`;
  }
}
