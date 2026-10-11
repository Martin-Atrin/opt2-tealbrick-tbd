import type { RemoteAgent } from "../shared/ipc";

/**
 * Which credential TBD sends to an agent: none that belongs to the person.
 *
 * Teal Brick v2 rule (PRD §4, CREDENTIALS R-P1): a person credential never
 * reaches an agent. The v1 interim (the owner's Portal session sent to owned
 * agents) is gone. Agent conversations get their own audience-bound credential
 * from the v2 pairing work; until then every agent request carries no
 * authorization header and the UI shows CREDENTIALS_WITHHELD.
 *
 * Pure on purpose: no host globals. controlPlane.ts wires it; tests use fakes.
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

/** What the person sees instead of a 401 when TBD keeps its credentials back. */
export const CREDENTIALS_WITHHELD =
  "This agent needs a Teal Brick v2 connection. TBD never sends your own credentials to an agent.";

const LOOPBACK_HOSTS = new Set(["localhost", "127.0.0.1"]);

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

export type WithheldReason = "person-credential-never-sent";
export type CredentialDecision = { mode: "none"; reason: WithheldReason };

export interface AgentAuth {
  /** Headers for one request to an agent. Never carries a person credential. */
  agentAuthHeaders(agent: ResolvedAgent, requestUrl: string, opts?: { json?: boolean }): Promise<Record<string, string>>;
  decide(agent: ResolvedAgent, requestUrl: string): Promise<CredentialDecision>;
}

export function createAgentAuth(): AgentAuth {
  return {
    async agentAuthHeaders(_agent, _requestUrl, opts = {}) {
      const headers: Record<string, string> = {};
      if (opts.json) headers["content-type"] = "application/json";
      return headers;
    },
    async decide() {
      return { mode: "none", reason: "person-credential-never-sent" };
    },
  };
}
