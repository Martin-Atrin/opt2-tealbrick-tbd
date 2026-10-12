import { createHash, randomBytes, randomUUID } from "node:crypto";
import type { DeviceAgentTokenResult, DeviceStart, DeviceStartAgentInput, DeviceTokenInput, ErrorEnvelope } from "@opt2-tealbrick/spec/routes";

/**
 * TBD's AGENT identity (CREDENTIALS §12 b, C24): a key connection.
 *
 * Device flow `client_id=tbd, scope=agent, harness=tbd-default` with the public
 * half of an Ed25519 key (K4) that the native host keeps in the Keychain. The
 * owner approves in the browser (the approval pre-selects "create card 'TBD on
 * <machine>'"); TBD then signs a short agent assertion and exchanges it at the
 * bridge `token_endpoint` for K5 (no refresh token: re-sign, C15).
 *
 * This module never sees the person token and never sends anything to Portal
 * owner routes. Only K5 leaves it, to the default agent's relay.
 */

export const TBD_HARNESS = "tbd-default";
const DEVICE_GRANT = "urn:ietf:params:oauth:grant-type:device_code" as const;
const JWT_BEARER = "urn:ietf:params:oauth:grant-type:jwt-bearer";

/** The native signer: private key stays in the Keychain. */
export interface AgentSigner {
  create(label: string): Promise<Ed25519Jwk>;
  publicJwk(label: string): Promise<Ed25519Jwk>;
  /** Signs a JWS signing input, returns base64url(signature). */
  sign(label: string, signingInput: string): Promise<string>;
  rename(from: string, to: string): Promise<void>;
  remove(label: string): Promise<void>;
}

export interface Ed25519Jwk { kty: "OKP"; crv: "Ed25519"; x: string }

/** Non-secret record of the approved connection (kept in the helper's state dir). */
export interface AgentConnection {
  connectionId: string;
  agentId: string;
  workspaceId: string;
  bridgeId: string;
  mcpUrl: string;
  tokenEndpoint: string;
  thumbprint: string;
}

export interface ConnectionStore {
  load(): AgentConnection | null;
  save(connection: AgentConnection | null): void;
}

export interface AgentIdentityDeps {
  origin: string;
  machineLabel: string;
  signer: AgentSigner;
  store: ConnectionStore;
  /** Bridge id for the assertion `aud` (REQUESTS: not yet in DeviceAgentTokenResult; TBD reads it with its person session). */
  bridgeIdFor(workspaceId: string, result: DeviceAgentTokenResult): Promise<string>;
  fetch?: typeof fetch;
  now?: () => number;
  sleep?: (ms: number) => Promise<void>;
}

export class AgentIdentityError extends Error {
  readonly code: string;
  constructor(code: string, message: string) {
    super(message);
    this.code = code;
  }
}

export const b64url = (data: Buffer | string): string => Buffer.from(data).toString("base64url");

/** RFC 7638 thumbprint of an OKP key: sha256 over {"crv","kty","x"} in lexical order. */
export function jwkThumbprint(jwk: Ed25519Jwk): string {
  return b64url(createHash("sha256").update(JSON.stringify({ crv: jwk.crv, kty: jwk.kty, x: jwk.x })).digest());
}

const CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
/** ULID (26 chars, no prefix) for `jti`. */
export function ulid(now = Date.now()): string {
  let time = "";
  let t = now;
  for (let i = 0; i < 10; i++) { time = CROCKFORD[t % 32] + time; t = Math.floor(t / 32); }
  const rand = randomBytes(16);
  let r = "";
  for (let i = 0; i < 16; i++) r += CROCKFORD[rand[i] % 32];
  return time + r;
}

export function createAgentIdentity(deps: AgentIdentityDeps) {
  const http = deps.fetch ?? fetch;
  const now = deps.now ?? Date.now;
  const sleep = deps.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));
  const base = `${new URL(deps.origin).origin}/api/v1`;
  let pending: { label: string; start: DeviceStart; jwk: Ed25519Jwk } | null = null;
  let cancelled = false;
  let access: { token: string; expiresAt: number } | null = null;

  async function portal<T>(path: string, body: unknown): Promise<T> {
    const res = await http(`${base}${path}`, {
      method: "POST",
      headers: { "content-type": "application/json", accept: "application/json" },
      body: JSON.stringify(body),
      redirect: "error",
      signal: AbortSignal.timeout(20_000),
    });
    const json = (await res.json().catch(() => null)) as unknown;
    if (!res.ok) {
      const env = json as Partial<ErrorEnvelope> | null;
      throw new AgentIdentityError(env?.error?.code ?? "internal", env?.error?.message ?? `Portal answered ${res.status}`);
    }
    return json as T;
  }

  async function assertion(c: AgentConnection): Promise<string> {
    const iat = Math.floor(now() / 1000);
    const header = { alg: "EdDSA", typ: "tb-agent-assert+jwt", kid: c.thumbprint };
    const payload = { iss: `tb:agt:${c.agentId}`, sub: `tb:agt:${c.agentId}`, aud: `tb:brg:${c.bridgeId}`, con: c.connectionId, iat, exp: iat + 60, jti: ulid(now()) };
    const input = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(payload))}`;
    return `${input}.${await deps.signer.sign(c.connectionId, input)}`;
  }

  return {
    connection: () => deps.store.load(),

    /** Step 1: new key + device request. The caller opens `verification_uri_complete` in the system browser. */
    async start(): Promise<DeviceStart> {
      cancelled = false;
      if (pending) await deps.signer.remove(pending.label).catch(() => {});
      const label = `pending-${randomUUID()}`;
      const jwk = await deps.signer.create(label);
      const input: DeviceStartAgentInput = { scope: "agent", client_id: "tbd", machine_label: deps.machineLabel.slice(0, 64), harness: TBD_HARNESS, agents: [{ public_key: jwk as never }] };
      try {
        const start = await portal<DeviceStart>("/device/authorize", input);
        pending = { label, start, jwk };
        return start;
      } catch (error) {
        await deps.signer.remove(label).catch(() => {});
        throw error;
      }
    },

    cancel(): void { cancelled = true; },

    /** Step 2: poll until approved; bind the key to the connection id. */
    async await(): Promise<AgentConnection> {
      const p = pending;
      if (!p) throw new AgentIdentityError("bad_request", "No agent connection request in progress.");
      let interval = Math.max(1, p.start.interval) * 1000;
      const deadline = now() + p.start.expires_in * 1000;
      const input: DeviceTokenInput = { grant_type: DEVICE_GRANT, device_code: p.start.device_code, client_id: "tbd" };
      try {
        while (now() < deadline) {
          await sleep(interval);
          if (cancelled) throw new AgentIdentityError("cancelled", "Connection cancelled.");
          let token: DeviceAgentTokenResult | { scope: string };
          try {
            token = await portal<DeviceAgentTokenResult | { scope: string }>("/device/token", input);
          } catch (error) {
            if (!(error instanceof AgentIdentityError)) throw error;
            if (error.code === "authorization_pending") continue;
            if (error.code === "slow_down") { interval += 5000; continue; }
            if (error.code === "access_denied") throw new AgentIdentityError(error.code, "The connection was denied in the browser.");
            if (error.code === "expired_token") break;
            throw error;
          }
          if (token.scope !== "agent") throw new AgentIdentityError("bad_request", "Portal returned a person token for an agent connection.");
          const result = token as DeviceAgentTokenResult;
          const thumbprint = jwkThumbprint(p.jwk);
          const mine = result.connections.find((c) => c.public_key_thumbprint === thumbprint) ?? (result.connections.length === 1 ? result.connections[0] : undefined);
          if (!mine) throw new AgentIdentityError("bad_request", "Portal did not return a connection for this key.");
          await deps.signer.rename(p.label, mine.connection_id);
          const connection: AgentConnection = {
            connectionId: mine.connection_id,
            agentId: mine.agent_id,
            workspaceId: result.workspace_id,
            bridgeId: (result as { bridge_id?: string }).bridge_id ?? await deps.bridgeIdFor(result.workspace_id, result),
            mcpUrl: result.mcp_url,
            tokenEndpoint: result.token_endpoint,
            thumbprint,
          };
          deps.store.save(connection);
          pending = null;
          return connection;
        }
        throw new AgentIdentityError("expired_token", "The connection code expired. Start again.");
      } finally {
        if (pending === p && (cancelled || now() >= deadline)) {
          await deps.signer.remove(p.label).catch(() => {});
          pending = null;
        }
      }
    },

    /** K5 for the relay: cached until 60 s before expiry; `connection_unknown` → retry with backoff ≤ 60 s. */
    async accessToken(opts: { maxWaitMs?: number } = {}): Promise<string> {
      if (access && access.expiresAt - 60_000 > now()) return access.token;
      const c = deps.store.load();
      if (!c) throw new AgentIdentityError("not_connected", "TBD's agent is not connected yet.");
      let backoff = 2000;
      const until = now() + (opts.maxWaitMs ?? 120_000);
      for (;;) {
        const res = await http(c.tokenEndpoint, {
          method: "POST",
          headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
          body: new URLSearchParams({ grant_type: JWT_BEARER, assertion: await assertion(c) }).toString(),
          redirect: "error",
          signal: AbortSignal.timeout(20_000),
        });
        const json = (await res.json().catch(() => ({}))) as { access_token?: string; expires_in?: number; error?: string; error_description?: string };
        if (res.ok && json.access_token) {
          access = { token: json.access_token, expiresAt: now() + (json.expires_in ?? 900) * 1000 };
          return access.token;
        }
        const waiting = json.error === "invalid_grant" && /connection_unknown/.test(json.error_description ?? "");
        if (!waiting || now() + backoff > until) {
          throw new AgentIdentityError(json.error ?? "token_failed", json.error_description ?? `Bridge answered ${res.status}`);
        }
        await sleep(backoff);
        backoff = Math.min(backoff * 2, 60_000);
      }
    },

    /** Forget the connection locally (revocation itself is the owner's, in Portal). */
    async disconnect(): Promise<void> {
      const c = deps.store.load();
      access = null;
      deps.store.save(null);
      if (c) await deps.signer.remove(c.connectionId).catch(() => {});
    },
  };
}

export type AgentIdentity = ReturnType<typeof createAgentIdentity>;
