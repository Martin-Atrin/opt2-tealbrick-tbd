/**
 * Whether TBD's agent has a model (Settings → Models → TBD agent model). The native check throws the
 * sentence to show; this module turns it into the readiness the UI reads and the guard every send
 * passes, so a message to an agent without a model is answered at once instead of going nowhere.
 */

export const NO_MODEL_NOTE = "No model set for TBD's agent. Set up a model in Settings → Models.";

export interface AgentModelReadiness {
  ready: boolean;
  note?: string;
}

/** Electron prefixes errors that crossed IPC; the person should read only the sentence. */
function plain(error: unknown): string {
  const text = error instanceof Error ? error.message : typeof error === "string" ? error : "";
  const cleaned = text.replace(/^Error invoking remote method '[^']+': /, "").replace(/^Error: /, "").trim();
  return cleaned || NO_MODEL_NOTE;
}

export async function agentModelReadiness(check: () => Promise<unknown>): Promise<AgentModelReadiness> {
  try {
    await check();
    return { ready: true };
  } catch (error) {
    return { ready: false, note: plain(error) };
  }
}

/** Throws the "No model set" sentence when the agent has no usable model; resolves otherwise. */
export async function requireAgentModel(check: () => Promise<unknown>): Promise<void> {
  const readiness = await agentModelReadiness(check);
  if (!readiness.ready) throw new Error(readiness.note ?? NO_MODEL_NOTE);
}
