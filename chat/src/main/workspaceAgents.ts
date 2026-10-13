import type { AgentCard, HarnessOptionList } from "@opt2-tealbrick/spec/routes";
import type { RemoteAgent, WorkspaceAgentState } from "../shared/ipc";

/**
 * The roster TBD Chat shows (C127, supersedes C24(1)): TBD's own agent first, then every other agent
 * card of the selected Portal workspace, read with the person's owner session (agents.list). Only
 * listing: chat with workspace agents comes later. Without Portal (not signed in, no workspace) the
 * roster is TBD's agent alone, with no error; a Portal failure keeps TBD's agent and adds a notice.
 */

export interface RosterPortal {
  agents(ws: string): Promise<AgentCard[]>;
  harnessOptions(): Promise<HarnessOptionList>;
}

export interface RosterInput {
  tbd: RemoteAgent;
  /** Null when TBD is not connected to a Portal workspace. */
  workspace: string | null;
  portal: RosterPortal | null;
  /** TBD's own card in that workspace (its agent connection), left out so TBD is not listed twice. */
  ownCardId?: string | null;
}

/** Card → state: paused wins, connected is online, everything else (pending, authorised) is offline. */
export function cardState(card: Pick<AgentCard, "status" | "paused">): WorkspaceAgentState {
  if (card.paused || card.status === "paused") return "paused";
  return card.status === "connected" ? "online" : "offline";
}

export function harnessLabel(id: string, options: HarnessOptionList | null): string | null {
  if (!id) return null;
  return options?.items.find((o) => o.id === id)?.label ?? id;
}

export function workspaceAgentRow(card: AgentCard, options: HarnessOptionList | null): RemoteAgent {
  const state = cardState(card);
  return {
    id: card.id,
    name: card.name,
    runtime: "workspace",
    url: null,
    accessMode: card.mode,
    audience: null,
    hasUrl: false,
    reachable: state === "online",
    daemonLabel: card.endpointLabel,
    peers: [],
    profile: null,
    workspace: { purpose: card.purpose, state, harness: harnessLabel(card.harnessOptionId, options) },
  };
}

function reason(error: unknown): string {
  const text = error instanceof Error ? error.message : String(error);
  return text.trim() || "Portal did not answer";
}

export async function buildRoster(input: RosterInput): Promise<RemoteAgent[]> {
  if (!input.portal || !input.workspace) return [input.tbd];
  let cards: AgentCard[];
  try {
    cards = await input.portal.agents(input.workspace);
  } catch (error) {
    return [{ ...input.tbd, rosterNotice: `The other agents of this workspace could not be loaded (${reason(error)}). TBD tries again in a minute.` }];
  }
  // Labels are decoration: without them the card's harness id is shown.
  const options = await input.portal.harnessOptions().catch(() => null);
  const others = cards
    .filter((c) => c.id !== input.ownCardId && c.id !== input.tbd.id)
    .map((c) => workspaceAgentRow(c, options));
  return [input.tbd, ...others];
}
