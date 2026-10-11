import type { Session } from "../shared/ipc";

/** Trusted-main credentials. Never return this object across IPC. */
export interface AuthSession extends Session {
  token: string;
  bundle?: string;
  refreshToken?: string;
}

export function publicSession(value: AuthSession): Session;
export function publicSession(value: AuthSession | null): Session | null;
export function publicSession(value: AuthSession | null): Session | null {
  if (!value) return null;
  return { expiresAt: value.expiresAt, email: value.email, orgName: value.orgName };
}

export const CUSTOMER_EXECUTION_REQUIRED = "Configure this connection in your customer runtime. Portal does not relay local execution or hold service credentials.";

/** Deliberate compatibility escape hatch for an operator-owned legacy server.
 * Both settings must be supplied, and the exact selected origin must match.
 * Hosted Teal Brick and the upstream hosted service can never opt in. */
export function legacyPortalExecutionEnabled(
  issuer: string,
  env: Record<string, string | undefined> = process.env,
): boolean {
  if (env.TEAL_BRICK_ALLOW_LEGACY_EXECUTION !== "1") return false;
  try {
    const origin = new URL(issuer);
    if (["portal.tealbrick.com", "agent.kybernesis.ai"].includes(origin.hostname.replace(/\.$/, ""))) return false;
    if (origin.origin !== issuer || origin.username || origin.password) return false;
    const local = ["localhost", "127.0.0.1", "[::1]"].includes(origin.hostname);
    if (origin.protocol !== "https:" && !(local && origin.protocol === "http:")) return false;
    return env.TEAL_BRICK_LEGACY_EXECUTION_ISSUER === issuer;
  } catch { return false; }
}

/** Only routing/lifecycle metadata may leave the customer desktop. */
export function sessionDirectoryRecord(entry: {
  agent: string; sessionId: string; lastMessageAt?: number; archived?: boolean;
}, workspaceId: string): Record<string, unknown> {
  return {
    agent: entry.agent,
    sessionId: entry.sessionId,
    lastMessageAt: entry.lastMessageAt,
    archived: entry.archived,
    workspaceId,
  };
}

export function debugStreamEnabled(value = process.env.KYBER_STUDIO_DEBUG_STREAM): boolean {
  return value === "1" || value === "true";
}

/** Never stringify stream data, input requests, error bodies or credentials. */
export function streamDiagnostic(type: string): string {
  return `[stream] event=${/^[a-z][a-z._-]{0,63}$/.test(type) ? type : "unknown"}`;
}
