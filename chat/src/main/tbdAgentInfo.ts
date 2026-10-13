/**
 * TBD's own agent as the agent panel and the composer menus see it: a native manifest
 * (renderer/lib/agentInfo.ts summarize()). The model is the "agent" route's model id from
 * Settings → Models (never the key); null when no model is set.
 */
export const TBD_TOOLS = [
  { name: "Companion timeline", description: "Your screen-activity timeline on this Mac." },
  { name: "Listen", description: "Your local transcripts, meetings and dictations." },
] as const;

export function tbdAgentInfo(modelName: string | null): Record<string, unknown> {
  return {
    name: "TBD",
    harness: "tbd-default",
    protocol: "tealbrick-native",
    native: true,
    ...(modelName ? { model: modelName } : {}),
    capabilities: ["chat", "resume", "cancel", "timeline", "transcripts"],
    tools: TBD_TOOLS.map((t) => ({ ...t })),
  };
}
