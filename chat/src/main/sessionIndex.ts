import { activeSession, agentFetch, authHeaders, issuer, resolveAgent } from "./controlPlane";
import {
  blocksFromEvents,
  type Replayed,
  type ReplayedBlock,
  type ReplayedPeerBlock,
} from "../shared/sessionReplay";
import { readPeerEvents } from "./peerEvents";

export { blocksFromEvents };
export type { Replayed, ReplayedBlock, ReplayedPeerBlock };

/**
 * Rebuild a conversation from the agent that holds it ({@link replaySession}).
 * The agent's event stream is durable and replays from the start with stable ids.
 */

/**
 * Rebuild a conversation from the agent's own event stream.
 *
 * Only finalized blocks are kept. The stream also carries every delta, every
 * tool call, and the agent's narration before it acts — replaying those would
 * reproduce the machinery of a conversation rather than the conversation, and
 * narration in particular arrives as a completed message whose finishReason is
 * "tool-calls". Rendering those as replies is how a transcript ends up reading
 * like someone thinking out loud.
 *
 * Bounded on purpose. A year-old thread can hold tens of thousands of events,
 * and opening it should not mean reading all of them; `limit` reads from the
 * tail and reports that it did.
 */
export async function replaySession(input: {
  agentId: string;
  sessionId: string;
  limit?: number;
}): Promise<Replayed | null> {
  let agent: Awaited<ReturnType<typeof resolveAgent>>;
  try {
    agent = await resolveAgent(input.agentId);
  } catch {
    return null;
  }
  if (typeof input.sessionId !== "string" || !input.sessionId) return null;

  const base = agent.url;
  const limit = Math.max(1, Math.min(Number(input.limit ?? 400) || 400, 5_000));

  // A negative startIndex reads relative to the tail, which is exactly the
  // "last N events" this needs — and avoids pulling a long history to throw
  // most of it away.
  const endpoint = `${base}/eve/v1/session/${encodeURIComponent(input.sessionId)}/stream?startIndex=-${limit}&includeTailIndex=1`;

  try {
    const res = await agentFetch(agent, endpoint, { signal: AbortSignal.timeout(60_000) });
    if (!res?.ok || !res.body) return null;

    const tailHeader = res.headers.get("x-eve-stream-tail-index");
    const tail = tailHeader === null ? -1 : Number(tailHeader);
    /**
     * How many events this read will produce before it is caught up.
     *
     * `includeTailIndex=1` REPORTS the tail; it does not end the response. The
     * stream follows the live session either way, so a reader that waits for
     * the connection to close waits forever — which is the same mistake that
     * made every agent-to-agent call time out against a long-lived host. The
     * cursor is ours to advance and ours to stop.
     */
    // With no tail header there is nothing to count towards, so fall back to the
    // caller's cap. On its own that is still not enough — a session with fewer
    // events than the cap would never reach it — so the read below also stops
    // when the stream goes quiet. Before both, a missing header (an older eve,
    // or a proxy that strips it) meant this loop could never break: it followed
    // the live session until the 60s abort, and the person who clicked a
    // conversation waited a full minute for an empty transcript.
    const expected = tail < 0 ? limit : Math.min(limit, tail + 1);

    // Collect the raw lines, then parse once. The transport concern here is
    // knowing when to stop; what the events MEAN is blocksFromEvents' job, and
    // keeping them apart is what lets the parser be tested against a captured
    // stream instead of only against a live agent.
    const lines: string[] = [];
    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    /** Quiet for this long means caught up: the stream follows a live session and never ends on its own. */
    const CAUGHT_UP_MS = 1_500;
    for (;;) {
      let idle: ReturnType<typeof setTimeout> | undefined;
      const chunk = await Promise.race([
        reader.read(),
        new Promise<"idle">((r) => {
          idle = setTimeout(() => r("idle"), CAUGHT_UP_MS);
        }),
      ]);
      clearTimeout(idle);
      if (chunk === "idle") {
        await reader.cancel().catch(() => {});
        break;
      }
      const { done, value } = chunk;
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      const parts = buffer.split("\n");
      // Keep the trailing fragment: chunk boundaries land mid-line often
      // enough that dropping it loses whole events under load.
      buffer = parts.pop() ?? "";
      for (const line of parts) if (line.trim()) lines.push(line);

      if (expected > 0 && lines.length >= expected) {
        await reader.cancel().catch(() => {});
        break;
      }
    }
    if (buffer.trim()) lines.push(buffer);

    const { blocks } = blocksFromEvents(lines);

    /**
     * Rebuild the agent-to-agent exchanges too, with the same reader the live
     * stream uses.
     *
     * Reusing it rather than writing a second parser is the point: peer traffic
     * has already been misread twice, and two implementations of the same rule
     * drift the moment one of them is fixed.
     */
    const peerBlocks: ReplayedPeerBlock[] = [];
    const peerState = { pending: new Map<string, string>(), last: null as string | null };
    for (const line of lines) {
      let event: { type?: string; data?: Record<string, unknown>; meta?: { at?: string } };
      try {
        event = JSON.parse(line);
      } catch {
        continue;
      }
      const found = readPeerEvents(event.type ?? "", event.data ?? {}, peerState);
      if (found.length === 0) continue;
      const turnId = String((event.data as { turnId?: unknown })?.turnId ?? "turn");
      const at = event.meta?.at ? Date.parse(String(event.meta.at)) : Date.now();
      const open = peerBlocks.find((b) => b.turnId === turnId);
      if (open) open.events.push(...found);
      else peerBlocks.push({ turnId, at: Number.isNaN(at) ? Date.now() : at, events: [...found] });
    }

    return {
      blocks,
      peerBlocks,
      streamIndex: tail >= 0 ? tail + 1 : lines.length,
      truncated: tail >= 0 && tail + 1 > limit,
    };
  } catch {
    return null;
  }
}
