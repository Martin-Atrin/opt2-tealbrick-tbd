import { createHash } from "node:crypto";
import { heldOf, pollHold, type McpClient, type McpToolResult } from "@opt2-tealbrick/bridge";
import { TOOL_NAME_RULE } from "@opt2-tealbrick/spec/bridge";
import type { AgentConnection } from "./agentIdentity";

/**
 * Listening's "Save to Knowledge" (WP10, C119). The call goes through TBD's OWN agent identity: the
 * key connection (K4 in the Keychain, signer socket) and the local relay — the same path the default
 * agent uses for its `tealbrick` tools. This module never sees the person session (K3) and never
 * calls Portal: its inputs are the agent connection (ids only) and a relay client. Grants, holds and
 * receipts apply as for any agent call; the deployed bridge decides everything.
 */

/** `knowledge__document_create` (Knowledge manifest op `document_create`, BRIDGE tool name rule). */
export const KNOWLEDGE_TOOL = `knowledge${TOOL_NAME_RULE.separator}document_create`;

export const KNOWLEDGE_MESSAGES = {
  notConnected: "Connect TBD's agent to your workspace first (Chat › agent panel › Connect).",
  noGrant: "TBD's agent has no Knowledge access. In Portal, open your workspace, draw a line from TBD's agent to Knowledge, choose Create, then press Connect.",
  waiting: "Waiting for owner approval",
  stillWaiting: "Still waiting for owner approval. Save again after the owner approves.",
  denied: "The owner declined saving this to Knowledge.",
  expired: "The owner approval expired. Save again to ask the owner again.",
  timeout: "Knowledge did not answer in time. Try again.",
  paused: "The owner paused TBD's agent. Ask the owner to resume it in Portal.",
  noDocumentId: "Knowledge did not return a document id. Try again.",
} as const;

export class KnowledgeSaveError extends Error {
  readonly code: keyof typeof KNOWLEDGE_MESSAGES | "app_error" | "input_invalid";
  constructor(message: string, code: KnowledgeSaveError["code"]) {
    super(message);
    this.name = "KnowledgeSaveError";
    this.code = code;
  }
}

/** What Listening sends (the person edited title and tags in the save sheet). */
export interface KnowledgeSaveInput {
  transcriptId: string;
  title: string;
  /** Header block (source URL, date, kind, duration) + transcript text. */
  body: string;
  /** One line: kind, date, source URL. */
  summary: string;
  tags: string[];
}

export interface KnowledgeSaveResult {
  documentId: string;
  area?: string;
}

export interface KnowledgeSaveDeps {
  /** TBD's agent connection (ids and URLs only), or null when the agent is not connected. */
  connection(): AgentConnection | null;
  /** One MCP client to the local relay, started for this connection (relayLaunch.ts). */
  openRelay(c: AgentConnection): Promise<McpClient>;
  /** Progress for the person ("Waiting for owner approval"). */
  onStatus?(message: string): void;
  /** Per-RPC timeout (L23). Default 30 s. */
  rpcTimeoutMs?: number;
  /** How long to wait for an owner decision before answering "still waiting". Default 10 min. */
  holdWaitMs?: number;
  /** Hold poll interval (pollHold enforces at least 10 s). */
  pollIntervalMs?: number;
}

/** The Knowledge manifest limits for `document_create` input. */
const LIMITS = { title: 200, body: 500_000, summary: 2_000, tags: 20, tag: 40 } as const;
const TRUNCATED = "\n\n[Transcript truncated]";

/** Exact `document_create` arguments: trimmed, deduplicated, within the manifest limits. */
export function documentArguments(input: KnowledgeSaveInput): { title: string; body: string; summary: string; tags: string[] } {
  const title = input.title.trim().slice(0, LIMITS.title);
  if (!title) throw new KnowledgeSaveError("Give the document a title.", "input_invalid");
  const body = input.body.length > LIMITS.body ? input.body.slice(0, LIMITS.body - TRUNCATED.length) + TRUNCATED : input.body;
  const tags: string[] = [];
  for (const raw of input.tags) {
    const tag = raw.trim().slice(0, LIMITS.tag);
    if (tag && !tags.includes(tag) && tags.length < LIMITS.tags) tags.push(tag);
  }
  return { title, body, summary: input.summary.trim().slice(0, LIMITS.summary), tags };
}

/**
 * Deterministic idempotency key: transcript id + hash of the exact arguments. A retry of the same
 * save (lost reply, restart, approval) never creates a second document. 8–128 chars (BRIDGE rule).
 */
export function idempotencyKey(transcriptId: string, args: ReturnType<typeof documentArguments>): string {
  const id = transcriptId.toLowerCase().replace(/[^a-z0-9-]/g, "").slice(0, 64) || "transcript";
  const hash = createHash("sha256").update(JSON.stringify([args.title, args.body, args.summary, args.tags])).digest("hex").slice(0, 32);
  return `tbd-knowledge-${id}-${hash}`;
}

function withTimeout<T>(work: Promise<T>, ms: number): Promise<T> {
  let timer: NodeJS.Timeout | undefined;
  const limit = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new KnowledgeSaveError(KNOWLEDGE_MESSAGES.timeout, "timeout")), ms);
  });
  return Promise.race([work, limit]).finally(() => clearTimeout(timer));
}

function errorOf(result: McpToolResult): KnowledgeSaveError {
  const env = result.structuredContent?.error as { code?: unknown; message?: unknown } | undefined;
  const code = typeof env?.code === "string" ? env.code : "app_error";
  if (code === "unknown_tool" || code === "forbidden" || code === "scope_denied") return new KnowledgeSaveError(KNOWLEDGE_MESSAGES.noGrant, "noGrant");
  if (code === "paused") return new KnowledgeSaveError(KNOWLEDGE_MESSAGES.paused, "paused");
  const text = typeof env?.message === "string" && env.message ? env.message : (result.content?.find((c) => c.type === "text")?.text ?? code);
  return new KnowledgeSaveError(`Knowledge did not save the document: ${text.slice(0, 300)}`, "app_error");
}

function resultOf(result: McpToolResult): KnowledgeSaveResult {
  if (result.isError) throw errorOf(result);
  const out = result.structuredContent ?? {};
  // manifest output: { id, area, version }
  const id = typeof out.id === "string" ? out.id : undefined;
  if (!id) throw new KnowledgeSaveError(KNOWLEDGE_MESSAGES.noDocumentId, "noDocumentId");
  return typeof out.area === "string" ? { documentId: id, area: out.area } : { documentId: id };
}

export async function knowledgeSave(input: KnowledgeSaveInput, deps: KnowledgeSaveDeps): Promise<KnowledgeSaveResult> {
  const connection = deps.connection();
  if (!connection) throw new KnowledgeSaveError(KNOWLEDGE_MESSAGES.notConnected, "notConnected");
  const rpc = deps.rpcTimeoutMs ?? 30_000;
  const args = documentArguments(input);
  const meta = { [TOOL_NAME_RULE.idempotencyMetaKey]: idempotencyKey(input.transcriptId, args) };
  const client = await withTimeout(deps.openRelay(connection), rpc);
  try {
    await withTimeout(client.initialize("tbd-listening"), rpc);
    const tools = await withTimeout(client.listTools(), rpc);
    // The relay lists only what the owner granted: no tool, no grant.
    if (!tools.some((t) => t.name === KNOWLEDGE_TOOL)) throw new KnowledgeSaveError(KNOWLEDGE_MESSAGES.noGrant, "noGrant");
    const call = () => withTimeout(client.callTool(KNOWLEDGE_TOOL, args, meta), rpc);
    const first = await call();
    const held = heldOf(first);
    if (!held) return resultOf(first);

    deps.onStatus?.(KNOWLEDGE_MESSAGES.waiting);
    // pollHold checks its signal only between waits; the cap answers at once and stops the poll loop.
    const stop = new AbortController();
    let capped = false;
    let cap: NodeJS.Timeout | undefined;
    const limit = new Promise<"expired">((resolve) => { cap = setTimeout(() => { capped = true; stop.abort(); resolve("expired"); }, deps.holdWaitMs ?? 600_000); });
    let outcome: "approved" | "denied" | "expired";
    try {
      // After the cap the relay client is closed: a late check must not touch it.
      const check: McpClient["callTool"] = (name, a, m) => (stop.signal.aborted ? Promise.reject(new Error("stopped")) : withTimeout(client.callTool(name, a, m), rpc));
      const poll = pollHold(check, held, { intervalMs: deps.pollIntervalMs, signal: stop.signal });
      outcome = await Promise.race([poll, limit]);
    } finally { clearTimeout(cap); stop.abort(); }
    if (outcome === "denied") throw new KnowledgeSaveError(KNOWLEDGE_MESSAGES.denied, "denied");
    if (outcome === "expired") throw new KnowledgeSaveError(capped ? KNOWLEDGE_MESSAGES.stillWaiting : KNOWLEDGE_MESSAGES.expired, capped ? "stillWaiting" : "expired");
    // Approved: repeat the exact same call (same arguments, same idempotency key).
    const second = await call();
    if (heldOf(second)) throw new KnowledgeSaveError(KNOWLEDGE_MESSAGES.stillWaiting, "stillWaiting");
    return resultOf(second);
  } finally {
    client.close();
  }
}
