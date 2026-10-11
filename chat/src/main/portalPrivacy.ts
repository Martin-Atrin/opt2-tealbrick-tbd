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

export function debugStreamEnabled(value = process.env.TBD_CHAT_DEBUG_STREAM): boolean {
  return value === "1" || value === "true";
}

/** Never stringify stream data, input requests, error bodies or credentials. */
export function streamDiagnostic(type: string): string {
  return `[stream] event=${/^[a-z][a-z._-]{0,63}$/.test(type) ? type : "unknown"}`;
}
