import type { Agent } from "@shared/types";

/**
 * What the canvas agent card (C146) shows for one agent, read from data Chat already has:
 * the name, the harness (a workspace agent's card names it; TBD's own agent reports it in its info)
 * and one status pill. Nothing here is invented: a missing value is left out, not guessed.
 *
 * Connected apps: no field of Agent, WorkspaceAgentInfo, RemoteAgent or the agent info names the
 * Teal Brick apps an agent is connected to (peers are other agents; `connections` are eve accounts),
 * so `appIds` stays empty until the data model gains such a field.
 *
 * Pure and import-free of siblings so node:test can load it.
 */

export type AgentTagKind = "live" | "busy" | "needs-you" | "idle";

export interface AgentCardModel {
  name: string;
  initial: string;
  harness?: string;
  status?: { kind: AgentTagKind; text: string };
  /** Ids of connected Teal Brick apps (lib/apps.generated.ts). */
  appIds: string[];
}

export interface AgentCardContext {
  /** TBD's own agent: the label of the harness its info reports (agentInfo.harnessLabel). */
  harness?: string;
  /** Set (to the sentence for the pill) when TBD's agent has no model and cannot answer. */
  modelBlocked?: string;
  /** A turn is in flight. */
  busy?: boolean;
  /** App ids named by the data, when it names any. */
  appIds?: readonly string[];
}

const STATE_TEXT = { online: "Online", paused: "Paused", offline: "Offline" } as const;

export function initialOf(name: string): string {
  return name.trim().charAt(0).toUpperCase() || "?";
}

export function agentStatus(agent: Pick<Agent, "status" | "workspace">, ctx: Pick<AgentCardContext, "modelBlocked" | "busy"> = {}): AgentCardModel["status"] {
  if (ctx.modelBlocked) return { kind: "needs-you", text: ctx.modelBlocked };
  if (ctx.busy) return { kind: "busy", text: "Working" };
  if (agent.workspace) {
    const state = agent.workspace.state;
    return { kind: state === "online" ? "live" : "idle", text: STATE_TEXT[state] };
  }
  if (agent.status === "online") return { kind: "live", text: "Online" };
  if (agent.status === "offline") return { kind: "idle", text: "Not answering" };
  return undefined;
}

export function agentCardModel(agent: Agent, ctx: AgentCardContext = {}): AgentCardModel {
  return {
    name: agent.name,
    initial: initialOf(agent.name),
    harness: agent.workspace ? (agent.workspace.harness ?? undefined) : ctx.harness,
    status: agentStatus(agent, ctx),
    appIds: [...(ctx.appIds ?? [])],
  };
}
