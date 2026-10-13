import type { WorkspaceAgentInfo, WorkspaceAgentState } from "../../../shared/ipc";

/** The read-only view of another workspace agent (C127). Chat transport comes later. */

export const CHAT_COMES_NEXT = "Chat with this agent comes next.";

export function stateLabel(state: WorkspaceAgentState): string {
  return state === "online" ? "Online" : state === "paused" ? "Paused" : "Offline";
}

/** The line under the name: state, then harness when the card names one. */
export function workspaceAgentSubtitle(info: WorkspaceAgentInfo): string {
  return [stateLabel(info.state), info.harness].filter(Boolean).join(" · ");
}
