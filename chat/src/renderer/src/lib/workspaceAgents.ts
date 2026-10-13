import type { WorkspaceAgentInfo, WorkspaceAgentState } from "../../../shared/ipc";

/** The read-only view of another workspace agent (C127). Chat transport comes later. */

export const CHAT_COMES_NEXT = "Chat with this agent comes next.";

/**
 * Which drawer view to show. A workspace agent has no TBD controls (connect, folders, reset, routines):
 * every view of it is its read-only profile.
 */
export function drawerView<V extends string>(agent: { workspace?: WorkspaceAgentInfo } | undefined, shown: V): V | "workspace-profile" {
  return agent?.workspace ? "workspace-profile" : shown;
}

/** The context-menu entry that opens the drawer for an agent. */
export function profileMenuLabel(agent: { workspace?: WorkspaceAgentInfo }): string {
  return agent.workspace ? "View Profile" : "Edit Profile";
}

export function stateLabel(state: WorkspaceAgentState): string {
  return state === "online" ? "Online" : state === "paused" ? "Paused" : "Offline";
}

/** The line under the name: state, then harness when the card names one. */
export function workspaceAgentSubtitle(info: WorkspaceAgentInfo): string {
  return [stateLabel(info.state), info.harness].filter(Boolean).join(" · ");
}
