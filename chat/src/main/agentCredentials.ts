import type { RemoteAgent } from "../shared/ipc";

/**
 * Which credential, if any, TBD sends to an agent (F4-1).
 *
 * The device-flow Portal session is an OWNER credential: the same bearer opens
 * /api/me/agents, mints agent credentials and grants local execution. Sending
 * it to every agent URL the directory or a room lists hands that power to
 * whoever runs the agent. So it now goes to exactly one kind of agent: one the
 * signed-in user owns, addressed at the exact origin (scheme, host and port)
 * Portal records for that agent. Everything else gets no credential at all and
 * a clear state instead of a confusing 401.
 *
 * Portal Core (#128) adds a per-agent chat token: POST /api/agents/chat-token
 * {agentId} → {token, expiresAt (ms), audience: "eve:<org>/<agentId>"}; 404
 * for an agent the user does not own, 409 agent_origin_not_allowed for an
 * owned agent off a Teal Brick origin. Behind TBD_AGENT_CHAT_TOKENS=1 TBD
 * sends that token (plus the policy bundle, which agents still check) and
 * never the session token, to any agent.
 *
 * Pure on purpose: no Electron, no globals. controlPlane.ts wires it to the
 * real session and directory; tests wire it to fakes.
 */

declare const resolvedBrand: unique symbol;

/**
 * An agent the MAIN process resolved from Portal's own /api/me/agents record.
 *
 * Branded so that nothing built from renderer input type-checks as one: every
 * credential-bearing request takes a ResolvedAgent, and the only way to get one
 * is `resolveRemoteAgent` over a directory row.
 */
export type ResolvedAgent = {
  readonly id: string;
  readonly name: string;
  /** Base URL, from the Portal record, without a trailing slash. */
  readonly url: string;
  /** `new URL(url).origin` — what every credential-bearing request must match exactly. */
  readonly origin: string;
  readonly audience: string | null;
  readonly accessMode: string;
  readonly ownerUserId: string | null;
  readonly [resolvedBrand]: true;
};

/**
 * The policy-bundle header agents read. Agents (kit portal/src/auth.ts) take
 * `x-tealbrick-bundle` and accept `x-kybernesis-bundle` only as a legacy
 * fallback, so agent calls send the current name. Portal calls keep theirs.
 */
export const AGENT_BUNDLE_HEADER = "x-tealbrick-bundle";

/** Feature flag for Portal chat tokens. Off until Core ships the endpoint. */
export const CHAT_TOKENS_ENV = "TBD_AGENT_CHAT_TOKENS";

/** What the person sees instead of a 401 when TBD keeps its credentials back. */
export const CREDENTIALS_WITHHELD =
  "This agent needs an updated connection. Teal Brick does not send your credentials to agents you do not run.";

/** Access modes in which the owner is the only intended user. */
const OWNER_ACCESS_MODES = new Set(["private", "owner"]);
const LOOPBACK_HOSTS = new Set(["localhost", "127.0.0.1"]);

export function chatTokensEnabled(env: Record<string, string | undefined> = process.env): boolean {
  return env[CHAT_TOKENS_ENV] === "1";
}

/** A Portal agent row as a ResolvedAgent, or null when it has no usable address. */
export function resolveRemoteAgent(remote: RemoteAgent): ResolvedAgent | null {
  if (!remote || typeof remote.id !== "string" || !remote.id || typeof remote.url !== "string") return null;
  let parsed: URL;
  try {
    parsed = new URL(remote.url);
  } catch {
    return null;
  }
  if (!["http:", "https:"].includes(parsed.protocol) || parsed.username || parsed.password) return null;
  return {
    id: remote.id,
    name: remote.name,
    url: remote.url.replace(/\/+$/, ""),
    origin: parsed.origin,
    audience: typeof remote.audience === "string" ? remote.audience : null,
    accessMode: String(remote.accessMode ?? ""),
    ownerUserId: typeof remote.ownerUserId === "string" && remote.ownerUserId ? remote.ownerUserId : null,
  } as ResolvedAgent;
}

/**
 * The origin of a URL a credential may travel to, or null.
 *
 * https only. Plain http is allowed for localhost/127.0.0.1 in development
 * builds, where a local agent has no certificate.
 */
export function credentialOrigin(raw: string, opts: { allowLoopbackHttp: boolean }): string | null {
  let parsed: URL;
  try {
    parsed = new URL(raw);
  } catch {
    return null;
  }
  if (parsed.username || parsed.password) return null;
  if (parsed.protocol === "https:") return parsed.origin;
  if (parsed.protocol === "http:" && opts.allowLoopbackHttp && LOOPBACK_HOSTS.has(parsed.hostname)) {
    return parsed.origin;
  }
  return null;
}

/**
 * Owned by the signed-in user, by Portal's own record.
 *
 * `ownerUserId` must be present and equal the session's `sub`. A row without
 * it is treated as NOT owned: an unknown owner is not the signed-in user.
 */
export function ownedBy(agent: ResolvedAgent, userId: string | null): boolean {
  return Boolean(userId) && OWNER_ACCESS_MODES.has(agent.accessMode) && agent.ownerUserId === userId;
}

export type WithheldReason =
  | "unknown-agent"
  | "insecure-origin"
  | "origin-mismatch"
  | "signed-out"
  | "not-owner"
  | "no-bundle"
  | "chat-token-unavailable";

export type CredentialDecision =
  | { mode: "owner-session" }
  | { mode: "chat-token" }
  | { mode: "none"; reason: WithheldReason };

/**
 * The one decision. `record` is the freshest directory row for the agent; the
 * caller's `agent` may be older (a cached client), so both, and the request,
 * must sit on the recorded origin.
 */
export function credentialDecision(input: {
  agent: ResolvedAgent;
  record: ResolvedAgent | null;
  requestUrl: string;
  userId: string | null;
  chatTokens: boolean;
  allowLoopbackHttp: boolean;
}): CredentialDecision {
  const { agent, record } = input;
  if (!record || record.id !== agent.id) return { mode: "none", reason: "unknown-agent" };
  const requestOrigin = credentialOrigin(input.requestUrl, input);
  if (!requestOrigin) return { mode: "none", reason: "insecure-origin" };
  if (requestOrigin !== record.origin || agent.origin !== record.origin) {
    return { mode: "none", reason: "origin-mismatch" };
  }
  if (input.chatTokens) return { mode: "chat-token" };
  if (!input.userId) return { mode: "none", reason: "signed-out" };
  if (!ownedBy(record, input.userId)) return { mode: "none", reason: "not-owner" };
  return { mode: "owner-session" };
}

/** Display-only JWT claims. Enforcement happens at the agent and at Portal. */
export function jwtClaims(jwt: string): Record<string, unknown> {
  try {
    const [, payload] = jwt.split(".");
    if (!payload) return {};
    const parsed = JSON.parse(Buffer.from(payload, "base64url").toString("utf8")) as unknown;
    return parsed && typeof parsed === "object" ? (parsed as Record<string, unknown>) : {};
  } catch {
    return {};
  }
}

export function sessionUserId(token: string | undefined): string | null {
  if (!token) return null;
  const sub = jwtClaims(token).sub;
  return typeof sub === "string" && sub ? sub : null;
}

export interface ChatTokenGrant {
  token: string;
  /** Epoch milliseconds. */
  expiresAt: number;
  audience: string;
}

/**
 * Validate Portal's answer to POST /api/agents/chat-token.
 *
 * The audience must name THIS agent (`eve:<org>/<agentId>`, or the audience
 * Portal recorded for it), and a JWT token's own `aud` must agree. A token that
 * equals the session token is refused: that would be the leak this exists to
 * stop, wearing a different name.
 */
export function parseChatToken(
  raw: unknown,
  agent: ResolvedAgent,
  sessionToken: string | undefined,
  now: number,
): ChatTokenGrant | null {
  if (!raw || typeof raw !== "object") return null;
  const body = raw as Record<string, unknown>;
  const token = typeof body.token === "string" ? body.token : "";
  const audience = typeof body.audience === "string" ? body.audience : "";
  if (!token || token === sessionToken) return null;
  const audienceNamesAgent =
    audience.startsWith("eve:") && (audience === agent.audience || audience.endsWith(`/${agent.id}`));
  if (!audienceNamesAgent) return null;
  const claims = jwtClaims(token);
  if (claims.aud !== undefined) {
    const auds = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
    if (!auds.includes(audience)) return null;
  }
  const expiresAt =
    typeof body.expiresAt === "number"
      ? body.expiresAt
      : typeof body.expiresAt === "string"
        ? Date.parse(body.expiresAt)
        : typeof claims.exp === "number"
          ? claims.exp * 1000
          : Number.NaN;
  if (!Number.isFinite(expiresAt) || expiresAt <= now) return null;
  return { token, expiresAt, audience };
}

export interface AgentAuthDeps {
  /** The live Portal session (refreshed by the caller), or null when signed out. */
  session(): Promise<{ token: string; bundle?: string } | null>;
  /** The freshest Portal record for an agent id in the current scope. */
  record(agentId: string): ResolvedAgent | null;
  /** POST /api/agents/chat-token {agentId}: the HTTP status and JSON body, or null on a network failure. */
  mintChatToken(agent: ResolvedAgent): Promise<{ status: number; body: unknown } | null>;
  allowLoopbackHttp(): boolean;
  chatTokens?(): boolean;
  now?(): number;
}

/** Re-mint this long before a chat token expires. */
const CHAT_TOKEN_SKEW_MS = 60_000;
/** After Portal refuses (404 not owned, 409 origin not allowed), ask again no sooner than this. */
const CHAT_TOKEN_REFUSAL_MS = 60_000;

export interface AgentAuth {
  /**
   * The headers for one request to an agent. The ONLY place an agent-bound
   * credential is attached. Returns no `authorization` when nothing may be sent.
   */
  agentAuthHeaders(
    agent: ResolvedAgent,
    requestUrl: string,
    opts?: { json?: boolean },
  ): Promise<Record<string, string>>;
  /** Why a request would or would not carry a credential (mints a chat token when needed). */
  decide(agent: ResolvedAgent, requestUrl: string): Promise<CredentialDecision>;
  /** The per-agent chat token, minted or cached. Null when Portal will not mint one. */
  agentToken(agent: ResolvedAgent): Promise<string | null>;
  /** Drop one agent's chat token (after a 401). */
  invalidate(agentId: string): void;
  /** Drop every chat token (sign-out). */
  clear(): void;
}

export function createAgentAuth(deps: AgentAuthDeps): AgentAuth {
  const tokens = new Map<string, ChatTokenGrant>();
  /** Agent id → when Portal last refused to mint for it. */
  const refused = new Map<string, number>();
  const minting = new Map<string, Promise<string | null>>();
  const now = (): number => (deps.now ? deps.now() : Date.now());
  const chatTokens = (): boolean => (deps.chatTokens ? deps.chatTokens() : chatTokensEnabled());

  async function decideWith(
    agent: ResolvedAgent,
    requestUrl: string,
    session: { token: string; bundle?: string } | null,
  ): Promise<CredentialDecision> {
    const decision = credentialDecision({
      agent,
      record: deps.record(agent.id),
      requestUrl,
      userId: sessionUserId(session?.token),
      chatTokens: chatTokens(),
      allowLoopbackHttp: deps.allowLoopbackHttp(),
    });
    if (decision.mode === "chat-token" && !session) return { mode: "none", reason: "signed-out" };
    if (decision.mode !== "none" && !session?.bundle) return { mode: "none", reason: "no-bundle" };
    return decision;
  }

  async function agentToken(agent: ResolvedAgent): Promise<string | null> {
    const cached = tokens.get(agent.id);
    if (cached && cached.expiresAt - CHAT_TOKEN_SKEW_MS > now()) return cached.token;
    tokens.delete(agent.id);
    const refusedAt = refused.get(agent.id);
    if (refusedAt !== undefined && now() - refusedAt < CHAT_TOKEN_REFUSAL_MS) return null;
    const pending = minting.get(agent.id);
    if (pending) return pending;
    const run = (async () => {
      try {
        const session = await deps.session();
        if (!session) return null;
        const minted = await deps.mintChatToken(agent);
        if (!minted) return null;
        if (minted.status === 404 || minted.status === 409) {
          refused.set(agent.id, now());
          return null;
        }
        if (minted.status < 200 || minted.status >= 300) return null;
        const grant = parseChatToken(minted.body, agent, session.token, now());
        if (!grant) return null;
        refused.delete(agent.id);
        tokens.set(agent.id, grant);
        return grant.token;
      } catch {
        return null;
      } finally {
        minting.delete(agent.id);
      }
    })();
    minting.set(agent.id, run);
    return run;
  }

  return {
    async agentAuthHeaders(agent, requestUrl, opts = {}) {
      const headers: Record<string, string> = {};
      if (opts.json) headers["content-type"] = "application/json";
      const session = await deps.session();
      const decision = await decideWith(agent, requestUrl, session);
      if (decision.mode === "chat-token") {
        // TODO(F4-1/Core): this is the only credential agents get once Portal
        // ships /api/agents/chat-token and the flag defaults on.
        const token = await agentToken(agent);
        if (token && session?.bundle) {
          headers.authorization = `Bearer ${token}`;
          // Agents still check the policy bundle beside the chat token (Core #128).
          headers[AGENT_BUNDLE_HEADER] = session.bundle;
        }
        return headers;
      }
      if (decision.mode === "owner-session" && session?.bundle) {
        // Interim: the owner's own agent, at the origin Portal recorded for it.
        headers.authorization = `Bearer ${session.token}`;
        headers[AGENT_BUNDLE_HEADER] = session.bundle;
      }
      return headers;
    },
    async decide(agent, requestUrl) {
      const decision = await decideWith(agent, requestUrl, await deps.session());
      if (decision.mode === "chat-token" && !(await agentToken(agent))) {
        return { mode: "none", reason: "chat-token-unavailable" };
      }
      return decision;
    },
    agentToken,
    invalidate(agentId) {
      tokens.delete(agentId);
      refused.delete(agentId);
    },
    clear() {
      tokens.clear();
      refused.clear();
      minting.clear();
    },
  };
}
