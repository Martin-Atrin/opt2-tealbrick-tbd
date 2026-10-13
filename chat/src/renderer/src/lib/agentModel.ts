import type { FirstRunState } from "../../../shared/ipc";

/**
 * "No model set" in Chat: TBD's own agent (C24, id "tbd-default") cannot answer without a model.
 * The row and the composer say so, and Send becomes "Set up a model" (Settings → Models).
 */

export const TBD_AGENT_ID = "tbd-default";
export const NO_MODEL_TITLE = "No model set";
export const SET_UP_MODEL = "Set up a model";
/**
 * Shown when the helper lists no agent at all. TBD Chat has exactly one agent, TBD's own, created by
 * this app (C24): there is nothing to bind in Portal, so the advice is to restart or update TBD.
 */
export const NO_AGENT_NOTE = "TBD's agent did not load. Quit and reopen TBD. If it is still missing, update TBD.";
const FALLBACK = "TBD's agent needs a model before it can answer. Set up a model in Settings → Models.";

export type AgentModelState = FirstRunState["model"] | null;

export interface ModelGate {
  /** Send is replaced by "Set up a model". */
  blocked: boolean;
  /** The sentence for the row and the composer. */
  note?: string;
}

/**
 * Blocks only TBD's agent, and only when the check said "not ready". Not checked yet (null) does not
 * block: the helper refuses such a send itself and the refusal shows in the conversation.
 */
export function modelGate(agentId: string, state: AgentModelState): ModelGate {
  if (agentId !== TBD_AGENT_ID || !state || state.ready) return { blocked: false };
  return { blocked: true, note: state.note?.trim() || FALLBACK };
}

/** The reply shown when a message to an agent without a model is not sent. */
export function notSentReply(note: string | undefined): string {
  return `Not sent: ${note?.trim() || FALLBACK}`;
}
