/**
 * F4-1 ACCEPTANCE (merge gate): the owner's device-flow Portal session never
 * reaches an agent the signed-in user does not run.
 *
 * Real code under test: src/main/controlPlane.ts and src/main/sessionIndex.ts,
 * bundled as they ship. Only Electron, the workspace selector and the control
 * plane picker are stubbed (none of them touch tokens). The session is issued
 * by a fake Portal through the REAL device-flow poll (pollDeviceAuth →
 * /api/oauth/token). Every agent is a header-logging HTTP server; each test
 * scans every header, URL, query and body those servers received.
 *
 * Agents:
 *   owned    — ownerUserId = signed-in user, accessMode private, at the exact
 *              origin Portal records (the only interim recipient of the session)
 *   foreign  — another user's agent in a shared room, on ANOTHER PORT of the
 *              same host (so "same host" is not enough)
 *   moved    — the owned agent after Portal moves it (stale record / port test)
 *   legacy   — owned, but Portal refuses it a chat token (409
 *              agent_origin_not_allowed: not on a Teal Brick origin)
 *
 * Pre-fix detection: on the old code (URL-based IPC/function signatures, no
 * `resolveAgent` export) `call()` below translates agentId → the Portal URL
 * and drives the OLD signatures, so every test runs the same scenario and
 * fails on the leak assertion — not on a missing export. The
 * "detector self-check" test runs ONLY on the old code and asserts the leak
 * IS detected; it is skipped once the old signature is gone.
 *
 * The fake Portal implements the Core #128 chat-token contract exactly:
 * POST /api/agents/chat-token {agentId} with the owner session →
 * 200 {token, expiresAt (ms), audience: "eve:<org>/<agentId>"};
 * 404 for an agent the user does not own; 409 agent_origin_not_allowed.
 */
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { build } from "esbuild";

const ROOT = resolve(import.meta.dirname, "..");
const ORG = "org-1";
const USER = "user-1";

const b64 = (value: unknown): string => Buffer.from(JSON.stringify(value)).toString("base64url");
const jwt = (claims: Record<string, unknown>, signature: string): string =>
  `${b64({ alg: "none", kid: "fixture" })}.${b64(claims)}.${signature}`;
const marker = (label: string): string => `${label}${Math.random().toString(36).slice(2, 12)}`;

/* ------------------------------------------------------------------ servers */

interface Logged { port: number; method: string; url: string; headers: Record<string, string | string[] | undefined>; body: string }

function listen(handler: (req: IncomingMessage, res: ServerResponse, body: string) => void): Promise<{ server: Server; port: number }> {
  return new Promise((ok) => {
    const server = createServer((req, res) => {
      let body = "";
      req.on("data", (c) => (body += c));
      req.on("end", () => handler(req, res, body));
    });
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      ok({ server, port: typeof address === "object" && address ? address.port : 0 });
    });
  });
}

const json = (res: ServerResponse, status: number, value: unknown, headers: Record<string, string> = {}): void => {
  res.writeHead(status, { "content-type": "application/json", ...headers });
  res.end(JSON.stringify(value));
};

/** A minimal eve agent that logs everything it receives. */
const control = new Map<number, { rejectNextAuthed: boolean }>();

async function fakeAgent(log: Logged[]): Promise<{ server: Server; port: number }> {
  const events: Record<string, unknown>[] = [];
  const state = { rejectNextAuthed: false };
  let deliveries = 0;
  const turn = (deliveryId: string | undefined): void => {
    const meta = deliveryId ? { deliveryIds: [deliveryId] } : {};
    events.push(
      { type: "turn.started", data: { turnId: `t${events.length}` }, meta },
      { type: "message.completed", data: { message: "hi", finishReason: "stop" }, meta },
      { type: "session.waiting", data: {}, meta },
    );
  };
  let port = 0;
  const started = await listen((req, res, body) => {
    log.push({ port, method: req.method ?? "", url: req.url ?? "", headers: req.headers, body });
    const url = new URL(req.url ?? "/", "http://fake");
    const path = url.pathname;
    const authed = typeof req.headers.authorization === "string";
    if (path === "/eve/v1/health") return authed ? json(res, 200, { ok: true }) : json(res, 401, { error: "unauthorized" });
    if (!authed) return json(res, 401, { error: "unauthorized" });
    if (state.rejectNextAuthed) {
      state.rejectNextAuthed = false;
      return json(res, 401, { error: "token_expired" });
    }
    if (path === "/eve/v1/info") return json(res, 200, { agent: { name: "fixture", model: "m" } });
    if (path === "/eve/v1/session" && req.method === "POST") {
      const deliveryId = `d${++deliveries}`;
      turn(deliveryId);
      return json(res, 200, { sessionId: "sess-1", deliveryId }, { "x-eve-session-id": "sess-1" });
    }
    if (path === "/eve/v1/session/sess-1" && req.method === "POST") {
      const parsed = JSON.parse(body || "{}") as { message?: unknown };
      const deliveryId = parsed.message !== undefined ? `d${++deliveries}` : undefined;
      turn(deliveryId);
      return json(res, 200, { sessionId: "sess-1", ...(deliveryId ? { deliveryId } : {}) });
    }
    if (path === "/eve/v1/session/sess-1/stream") {
      const raw = Number(url.searchParams.get("startIndex") ?? "0");
      const start = raw < 0 ? Math.max(0, events.length + raw) : raw;
      res.writeHead(200, {
        "content-type": "application/x-ndjson",
        "x-eve-stream-version": "25",
        "x-eve-stream-tail-index": String(events.length - 1),
      });
      res.end(events.slice(start).map((e) => `${JSON.stringify(e)}\n`).join(""));
      return;
    }
    if (path === "/eve/v1/session/sess-1/cancel") return json(res, 200, { ok: true, status: "no_active_turn" });
    if (path === "/eve/v1/session/sess-1/reset") return json(res, 200, { ok: true, status: "no_active_session" });
    if (path === "/eve/v1/session/sess-1/access") {
      return json(res, 200, { sessionId: "sess-1", mode: "restricted", sandbox: "s", shell: false, approvalPolicy: "a", revision: 1 });
    }
    if (path === "/eve/v1/voice/manifest") return json(res, 200, { enabled: true, voice: "marin" });
    if (path === "/eve/v1/voice/session") return json(res, 200, { ok: true, sdp: "answer" });
    if (path === "/eve/v1/kyb/credential") return json(res, 200, { restarted: false });
    if (path === "/tealbrick/v1/capabilities") return json(res, 200, { schema: 1 });
    if (path.startsWith("/eve/v1/kyb/") || path === "/eve/v1/tealbrick/management") return json(res, 200, { ok: true });
    return json(res, 404, { error: "not_found" });
  });
  port = started.port;
  control.set(port, state);
  return started;
}

/* ------------------------------------------------------------------ fixture */

const secrets = { token: "", bundle: "", refresh: "", sessionSig: marker("SESSIONSIG"), bundleSig: marker("BUNDLESIG") };
secrets.token = jwt({ typ: "user", org: ORG, sub: USER, email: "owner@example.test", exp: Math.floor(Date.now() / 1000) + 3600 }, secrets.sessionSig);
secrets.bundle = jwt({ org: ORG, user: USER, exp: Math.floor(Date.now() / 1000) + 3600 }, secrets.bundleSig);
secrets.refresh = marker("REFRESH");

const agentLog: Logged[] = [];
const servers: Server[] = [];
const ports = { portal: 0, owned: 0, foreign: 0, moved: 0, legacy: 0 };
const portal = { ownedPort: 0, mints: [] as string[], chatTokens: new Map<string, string>() };
let dir = "";
let bundlePath = "";
let instance = 0;

const agentRows = (): Record<string, unknown>[] => [
  { id: "agt-owned", name: "owned", runtime: "eve", url: `http://127.0.0.1:${portal.ownedPort}`, accessMode: "private", audience: `eve:${ORG}/owned`, ownerUserId: USER, reachable: true, daemonLabel: null },
  { id: "agt-foreign", name: "foreign", runtime: "eve", url: `http://127.0.0.1:${ports.foreign}`, accessMode: "org", audience: `eve:${ORG}/foreign`, ownerUserId: "user-2", reachable: true, daemonLabel: null },
  { id: "agt-legacy", name: "legacy", runtime: "eve", url: `http://127.0.0.1:${ports.legacy}`, accessMode: "private", audience: `eve:${ORG}/legacy`, ownerUserId: USER, reachable: true, daemonLabel: null },
];

before(async () => {
  for (const key of ["owned", "foreign", "moved", "legacy"] as const) {
    const started = await fakeAgent(agentLog);
    servers.push(started.server);
    ports[key] = started.port;
  }
  portal.ownedPort = ports.owned;
  const p = await listen((req, res, body) => {
    const url = new URL(req.url ?? "/", "http://portal");
    const path = url.pathname;
    if (path === "/api/oauth/device") return json(res, 200, { device_code: "dc", user_code: "UC", verification_uri: "http://portal/verify", interval: 0, expires_in: 30 });
    if (path === "/api/oauth/token" || path === "/api/oauth/refresh") {
      return json(res, 200, { token: secrets.token, bundle: secrets.bundle, refresh_token: secrets.refresh });
    }
    if (req.headers.authorization !== `Bearer ${secrets.token}`) return json(res, 401, { error: "unauthorized" });
    if (path === "/api/me/agents") return json(res, 200, { workspaceId: "ws1", agents: agentRows() });
    if (path === "/api/rooms") {
      return json(res, 200, { workspaceId: "ws1", rooms: [{ id: "room-1", name: "Shared", members: ["owned", "foreign"], policy: "all", pinned: null, createdAt: "", updatedAt: "" }] });
    }
    if (path === "/api/agents/chat-token") {
      const agentId = String((JSON.parse(body || "{}") as { agentId?: unknown }).agentId ?? "");
      portal.mints.push(agentId);
      const row = agentRows().find((a) => a.id === agentId);
      if (!row || row.ownerUserId !== USER) return json(res, 404, { error: "not_found" });
      if (agentId === "agt-legacy") return json(res, 409, { error: "agent_origin_not_allowed" });
      const audience = `eve:${ORG}/${agentId}`;
      const token = jwt({ aud: audience, sub: USER, exp: Math.floor(Date.now() / 1000) + 300 }, marker(`CHATSIG${agentId}`));
      portal.chatTokens.set(agentId, token);
      return json(res, 200, { token, audience, expiresAt: Date.now() + 300_000 });
    }
    return json(res, 200, { ok: true, grants: [], credential: marker("AGENTCRED") });
  });
  servers.push(p.server);
  ports.portal = p.port;

  dir = mkdtempSync(join(tmpdir(), "tbd-f41-"));
  const stubs: Record<string, string> = {
    electron: `export const app = { getPath: () => globalThis.__F41_DIR, isPackaged: false, emit() {}, on() {} };
      export const safeStorage = { isEncryptionAvailable: () => false, encryptString: (s) => Buffer.from(s), decryptString: (b) => String(b) };
      export const shell = { openExternal: async () => {} };`,
    "./portalWorkspaces": `export const selectedPortalWorkspace = () => "ws1"; export const resetPortalWorkspace = () => {};`,
    "./controlPlanes": `export const currentControlPlane = () => ({ issuer: globalThis.__F41_ISSUER });`,
  };
  const result = await build({
    stdin: {
      contents: `export * from "./src/main/controlPlane.ts"; export { replaySession } from "./src/main/sessionIndex.ts";`,
      resolveDir: ROOT,
      loader: "ts",
    },
    bundle: true,
    platform: "node",
    format: "esm",
    write: false,
    logLevel: "silent",
    banner: { js: `import { createRequire as __f41Require } from "node:module"; const require = __f41Require(import.meta.url);` },
    plugins: [{
      name: "f41-stubs",
      setup(b) {
        b.onResolve({ filter: /^(electron|\.\/portalWorkspaces|\.\/controlPlanes)$/ }, (args) => ({ path: args.path, namespace: "f41" }));
        b.onLoad({ filter: /.*/, namespace: "f41" }, (args) => ({ contents: stubs[args.path], loader: "js" }));
      },
    }],
  });
  bundlePath = join(dir, "control-plane.mjs");
  writeFileSync(bundlePath, result.outputFiles[0]!.text);
  (globalThis as Record<string, unknown>).__F41_DIR = dir;
  (globalThis as Record<string, unknown>).__F41_ISSUER = `http://127.0.0.1:${ports.portal}`;
});

after(() => {
  for (const server of servers) server.close();
  if (dir) rmSync(dir, { recursive: true, force: true });
});

type Api = Record<string, (...args: never[]) => Promise<unknown>> & Record<string, unknown>;

/** A fresh copy of the real module, signed in through the real device flow. */
async function signedIn(env: Record<string, string | undefined> = {}): Promise<Api> {
  for (const key of ["TBD_AGENT_CHAT_TOKENS", "TEAL_BRICK_ALLOW_LEGACY_EXECUTION", "TEAL_BRICK_LEGACY_EXECUTION_ISSUER"]) delete process.env[key];
  Object.assign(process.env, env);
  const api = (await import(`${pathToFileURL(bundlePath).href}?instance=${++instance}`)) as Api;
  const call = api as unknown as Record<string, (...args: unknown[]) => Promise<unknown>>;
  const start = (await call.startDeviceAuth!()) as Record<string, unknown>;
  await call.pollDeviceAuth!(start);
  return api;
}

const quiet = async <T>(fn: () => Promise<T>): Promise<{ ok: true; value: T } | { ok: false; error: string }> => {
  const log = console.log;
  console.log = () => {};
  try {
    return { ok: true, value: await fn() };
  } catch (error) {
    return { ok: false, error: error instanceof Error ? error.message : String(error) };
  } finally {
    console.log = log;
  }
};

/** The pre-fix code: URL-based signatures, no main-side resolution. */
const isPreFix = (api: Api): boolean => typeof api.resolveAgent !== "function";

/**
 * Call a controlPlane function by agent id. On the pre-fix code, translate to
 * its old signature: a bare URL, or `{ url, agent: <name> }` in place of
 * `{ agentId }` — exactly what the old renderer sent over IPC.
 */
function caller(api: Api): Record<string, (arg?: unknown) => Promise<unknown>> {
  const fns = api as unknown as Record<string, (...args: unknown[]) => Promise<unknown>>;
  const old = isPreFix(api);
  const row = (agentId: string): Record<string, unknown> => agentRows().find((a) => a.id === agentId) ?? {};
  return new Proxy({}, {
    get: (_t, name: string) => async (arg?: unknown) => {
      const fn = fns[name];
      if (typeof fn !== "function") throw new Error(`${name} is not exported`);
      if (!old) return await fn(arg);
      if (typeof arg === "string" && row(arg).url) return await fn(row(arg).url);
      if (arg && typeof arg === "object" && "agentId" in arg) {
        const { agentId, ...rest } = arg as { agentId: string } & Record<string, unknown>;
        return await fn({ ...rest, url: row(agentId).url, agent: row(agentId).name });
      }
      return await fn(arg);
    },
  });
}

/** Every leak of an owner credential in what an agent received. */
function findLeaks(entries: Logged[], secretsToFind = [secrets.token, secrets.sessionSig, secrets.bundle, secrets.bundleSig, secrets.refresh]): string[] {
  const leaks: string[] = [];
  for (const entry of entries) {
    for (const surface of surfaces(entry)) {
      if (secretsToFind.some((secret) => surface.includes(secret))) leaks.push(`${entry.method} ${entry.url}`);
    }
    for (const header of ["x-kybernesis-bundle", "x-tealbrick-bundle"]) {
      if (entry.headers[header] !== undefined && secretsToFind.includes(secrets.bundle)) leaks.push(`${header} on ${entry.url}`);
    }
  }
  return [...new Set(leaks)];
}

/** Every agent-facing path this PR routes through agentAuthHeaders. */
async function driveEverything(api: Api, agentId: string): Promise<Record<string, Awaited<ReturnType<typeof quiet>>>> {
  const c = caller(api);
  const noop = (): void => {};
  const turnCallbacks = { onDelta: noop, onReset: noop, onActivity: noop, onCursor: noop, onAuthorization: noop, onQuestion: noop, onPeer: noop };
  const out: Record<string, Awaited<ReturnType<typeof quiet>>> = {};
  out.health = await quiet(() => c.agentHealth!(agentId));
  out.info = await quiet(() => c.agentInfo!(agentId));
  out.send = await quiet(() => c.sendTurn!({ agentId, text: "hello", ...turnCallbacks }));
  const sessionId = out.send.ok ? ((out.send.value as { sessionId?: string }).sessionId ?? "sess-1") : "sess-1";
  // Continuing a session reads the stream tail first (tailIndex).
  out.sendAgain = await quiet(() => c.sendTurn!({ agentId, text: "again", sessionId, streamIndex: 0, ...turnCallbacks }));
  // Answering a question / approval: respond, no new message.
  out.respond = await quiet(() => c.sendTurn!({ agentId, text: "", sessionId, streamIndex: 0, inputResponses: [{ requestId: "r1", optionId: "approve" }], ...turnCallbacks }));
  out.replay = await quiet(() => c.replaySession!({ agentId, sessionId }));
  const watch = new AbortController();
  setTimeout(() => watch.abort(), 400);
  out.watch = await quiet(() => c.watchSession!({ agentId, sessionId, startIndex: 0, signal: watch.signal, ...turnCallbacks, onLive: noop }));
  out.cancel = await quiet(() => c.cancelTurn!({ agentId, sessionId }));
  out.reset = await quiet(() => c.resetSession!({ agentId, sessionId }));
  out.catalog = await quiet(() => c.manageCall!({ agentId, path: "/catalog" }));
  out.install = await quiet(() => c.manageCall!({ agentId, path: "/install", body: { item: "x" } }));
  out.capabilities = await quiet(() => c.manageCall!({ agentId, path: "/tealbrick/capabilities" }));
  out.management = await quiet(() => c.manageCall!({ agentId, path: "/tealbrick/management" }));
  out.voiceManifest = await quiet(() => c.voiceManifest!(agentId));
  out.voiceSession = await quiet(() => c.voiceSession!({ agentId, sdp: "offer" }));
  out.codexRead = await quiet(() => c.codexAccess!({ agentId, sessionId }));
  out.codexWrite = await quiet(() => c.codexAccess!({ agentId, sessionId, mode: "restricted", revision: 1, confirmed: false }));
  out.provision = await quiet(() => c.provisionLocalAccess!({ agentId }));
  return out;
}

/** Every place a credential could hide in what an agent received. */
function surfaces(entry: Logged): string[] {
  return [entry.url, entry.body, ...Object.entries(entry.headers).flatMap(([k, v]) => [k, ...(Array.isArray(v) ? v : [String(v ?? "")])])];
}

function assertNoOwnerCredentials(entries: Logged[], label: string): void {
  const leaks = findLeaks(entries);
  assert.deepEqual(leaks, [], `LEAK: owner credential sent to ${label}: ${leaks.join(", ")}`);
}

const logFor = (port: number, from: number): Logged[] => agentLog.slice(from).filter((e) => e.port === port);

/* ---------------------------------------------------------------- the tests */

test("interim: in a shared room, the owned agent gets the owner session and the foreign agent gets NO credential on any path", async () => {
  portal.ownedPort = ports.owned;
  const api = await signedIn({ TEAL_BRICK_ALLOW_LEGACY_EXECUTION: "1", TEAL_BRICK_LEGACY_EXECUTION_ISSUER: `http://127.0.0.1:${ports.portal}` });
  const c = caller(api);
  const mark = agentLog.length;

  // The room path: members by registered name, resolved to ids as the renderer does.
  const rooms = (await c.listRooms!()) as { members: string[] }[];
  const agents = (await c.listAgents!()) as { id: string; name: string; connection?: { mode: string } }[];
  const members = rooms[0]!.members.map((name) => agents.find((a) => a.name === name)!);
  assert.deepEqual(members.map((m) => m.id), ["agt-owned", "agt-foreign"]);

  const owned = await driveEverything(api, members[0]!.id);
  const foreign = await driveEverything(api, members[1]!.id);

  // THE GATE, checked first so the pre-fix code fails here, on the leak.
  const foreignLog = logFor(ports.foreign, mark);
  assertNoOwnerCredentials(foreignLog, "foreign room member");

  assert.equal(members[0]!.connection?.mode, "owner-session");
  assert.equal(members[1]!.connection?.mode, "withheld");

  // Positive control: the fake agent is real enough that every path worked.
  assert.deepEqual(owned.health, { ok: true, value: true });
  assert.ok(owned.info.ok && owned.info.value, "info");
  assert.ok(owned.send.ok && (owned.send.value as { reply: string }).reply === "hi", `send: ${JSON.stringify(owned.send)}`);
  assert.ok(owned.sendAgain.ok, `sendAgain: ${JSON.stringify(owned.sendAgain)}`);
  assert.ok(owned.respond.ok, `respond: ${JSON.stringify(owned.respond)}`);
  assert.ok(owned.replay.ok && owned.replay.value, "replay");
  for (const key of ["catalog", "install", "capabilities", "management"]) {
    assert.ok(owned[key]!.ok && (owned[key]!.value as { ok: boolean }).ok, `${key}: ${JSON.stringify(owned[key])}`);
  }
  assert.ok(owned.voiceManifest.ok && owned.voiceManifest.value, "voiceManifest");
  assert.ok(owned.voiceSession.ok, `voiceSession: ${JSON.stringify(owned.voiceSession)}`);
  assert.ok(owned.codexRead.ok && owned.codexWrite.ok, "codex");
  assert.ok(owned.provision.ok && (owned.provision.value as { ok: boolean }).ok, `provision: ${JSON.stringify(owned.provision)}`);
  const ownedLog = logFor(ports.owned, mark);
  const ownedAuthed = ownedLog.filter((e) => e.headers.authorization);
  assert.ok(ownedAuthed.length >= 15, `owned agent saw ${ownedAuthed.length} authenticated requests`);
  for (const e of ownedAuthed) assert.equal(e.headers.authorization, `Bearer ${secrets.token}`);
  // The 401 health retry happened, with the session, to the owned agent only.
  assert.equal(ownedLog.filter((e) => e.url === "/eve/v1/health").length, 2);

  // The foreign agent: reached (the unauthenticated health probe) and never credentialed.
  assert.deepEqual(foreignLog.map((e) => e.url), ["/eve/v1/health"], "only the unauthenticated health probe reaches it");
  assert.equal(foreignLog[0]!.headers.authorization, undefined);
  assert.deepEqual(foreign.health, { ok: true, value: false });
  for (const key of ["send", "sendAgain", "respond", "watch", "cancel", "reset", "voiceSession", "codexRead", "codexWrite"]) {
    assert.ok(!foreign[key]!.ok && /do not run/.test(foreign[key]!.error), `${key}: ${JSON.stringify(foreign[key])}`);
  }
  for (const key of ["catalog", "install", "capabilities", "management"]) {
    assert.equal((foreign[key]!.value as { status: number }).status, 428, key);
  }
  assert.ok(foreign.provision.ok && /do not run/.test(String((foreign.provision.value as { error?: string }).error)), "provision");
});

test("an owned agent addressed at another port of the same host (stale or manipulated record) gets NO session", async () => {
  portal.ownedPort = ports.owned;
  const api = await signedIn();
  const c = api as unknown as Record<string, (...args: unknown[]) => Promise<unknown>>;
  if (isPreFix(api)) {
    // The old IPC took any URL: the owned agent's host on another port.
    const mark = agentLog.length;
    await quiet(() => c.agentInfo!(`http://127.0.0.1:${ports.moved}`));
    assertNoOwnerCredentials(logFor(ports.moved, mark), "another port of the owned agent's host");
  }
  const stale = (await c.resolveAgent!("agt-owned")) as Record<string, string>;
  assert.equal(stale.origin, `http://127.0.0.1:${ports.owned}`);

  // Manipulated: the recorded agent, but a request URL on another port.
  const otherPort = (await c.agentAuthHeaders!(stale, `http://127.0.0.1:${ports.moved}/eve/v1/info`)) as Record<string, string>;
  assert.equal(otherPort.authorization, undefined);
  // Manipulated: a forged record pointing at another port.
  const forged = { ...stale, url: `http://127.0.0.1:${ports.moved}`, origin: `http://127.0.0.1:${ports.moved}` };
  assert.equal(((await c.agentAuthHeaders!(forged, `${forged.url}/eve/v1/info`)) as Record<string, string>).authorization, undefined);
  // The recorded origin itself still works (positive control).
  assert.equal(((await c.agentAuthHeaders!(stale, `${stale.url}/eve/v1/info`)) as Record<string, string>).authorization, `Bearer ${secrets.token}`);

  // Portal moves the agent. The cached (stale) record must stop carrying the
  // session even toward its own old origin.
  portal.ownedPort = ports.moved;
  await c.listAgents!();
  const mark = agentLog.length;
  assert.equal(((await c.agentAuthHeaders!(stale, `${stale.url}/eve/v1/info`)) as Record<string, string>).authorization, undefined);
  // Real paths now go to the new recorded origin and nowhere else.
  assert.ok(await c.agentInfo!("agt-owned"));
  assert.equal(logFor(ports.owned, mark).length, 0, "the old port receives nothing");
  assert.ok(logFor(ports.moved, mark).some((e) => e.headers.authorization === `Bearer ${secrets.token}`));
  portal.ownedPort = ports.owned;
});

test("chat-token flag ON: the owned agent gets only its own audience-bound chat token (+ bundle); foreign and off-origin agents get nothing; the session goes to no agent", async () => {
  portal.ownedPort = ports.owned;
  portal.mints.length = 0;
  const api = await signedIn({ TBD_AGENT_CHAT_TOKENS: "1" });
  const c = caller(api);
  const mark = agentLog.length;
  const owned = await driveEverything(api, "agt-owned");
  const foreign = await driveEverything(api, "agt-foreign");
  const legacy = await driveEverything(api, "agt-legacy");
  assert.ok(owned.send.ok && (owned.send.value as { reply: string }).reply === "hi", JSON.stringify(owned.send));
  assert.deepEqual(owned.health, { ok: true, value: true });

  // No agent ever sees the session token or the refresh token.
  for (const [label, port] of [["owned", ports.owned], ["foreign", ports.foreign], ["off-origin", ports.legacy]] as const) {
    const leaks = findLeaks(logFor(port, mark), [secrets.token, secrets.sessionSig, secrets.refresh]);
    assert.deepEqual(leaks, [], `LEAK: session sent to the ${label} agent: ${leaks.join(", ")}`);
  }
  // The owned agent: its own chat token (aud = eve:<org>/agt-owned) and the bundle, every time.
  const own = portal.chatTokens.get("agt-owned")!;
  assert.equal(JSON.parse(Buffer.from(own.split(".")[1]!, "base64url").toString()).aud, `eve:${ORG}/agt-owned`);
  const authed = logFor(ports.owned, mark).filter((e) => e.headers.authorization);
  assert.ok(authed.length >= 15, `owned agent saw ${authed.length} authenticated requests`);
  for (const e of authed) {
    assert.equal(e.headers.authorization, `Bearer ${own}`);
    assert.equal(e.headers["x-tealbrick-bundle"], secrets.bundle, "agents still check the bundle beside the chat token");
    assert.equal(e.headers["x-kybernesis-bundle"], undefined, "agent calls use the current bundle header name");
  }
  // Foreign (Portal 404) and off-origin (Portal 409): no credential of any kind.
  for (const [label, port, result] of [["foreign", ports.foreign, foreign], ["legacy", ports.legacy, legacy]] as const) {
    const entries = logFor(port, mark);
    assertNoOwnerCredentials(entries, label);
    assert.deepEqual(entries.map((e) => e.url), ["/eve/v1/health"], `${label}: only the unauthenticated health probe`);
    for (const key of ["send", "respond", "watch", "voiceSession", "codexRead"]) {
      assert.ok(!result[key]!.ok && /do not run/.test(result[key]!.error), `${label} ${key}: ${JSON.stringify(result[key])}`);
    }
    assert.equal((result.catalog.value as { status: number }).status, 428);
  }
  // Cached per agent, and a refusal is not re-asked on every request.
  assert.deepEqual(portal.mints.filter((id) => id === "agt-owned").length, 1);
  assert.deepEqual(portal.mints.filter((id) => id === "agt-foreign").length, 1);
  assert.deepEqual(portal.mints.filter((id) => id === "agt-legacy").length, 1);

  // A 401 from the agent re-mints once and retries with the new token.
  control.get(ports.owned)!.rejectNextAuthed = true;
  const retried = (await c.manageCall!({ agentId: "agt-owned", path: "/catalog" })) as { ok: boolean };
  assert.equal(retried.ok, true);
  assert.equal(portal.mints.filter((id) => id === "agt-owned").length, 2);
  const last = logFor(ports.owned, mark).at(-1)!;
  assert.equal(last.headers.authorization, `Bearer ${portal.chatTokens.get("agt-owned")}`);
  assert.notEqual(portal.chatTokens.get("agt-owned"), own);
});

test("sign-out drops chat tokens and directory: nothing is credentialed afterwards", async () => {
  const api = await signedIn({ TBD_AGENT_CHAT_TOKENS: "1" });
  const c = api as unknown as Record<string, (...args: unknown[]) => unknown>;
  if (isPreFix(api)) {
    const mark = agentLog.length;
    await quiet(async () => await caller(api).agentInfo!("agt-foreign"));
    assertNoOwnerCredentials(logFor(ports.foreign, mark), "foreign agent (flag on)");
  }
  const owned = (await c.resolveAgent!("agt-owned")) as Record<string, string>;
  assert.ok(((await c.agentAuthHeaders!(owned, `${owned.url}/eve/v1/info`)) as Record<string, string>).authorization);
  c.signOut!();
  assert.equal(((await c.agentAuthHeaders!(owned, `${owned.url}/eve/v1/info`)) as Record<string, string>).authorization, undefined);
});

/**
 * Detector self-check, for QA. Runs ONLY against the pre-fix code (the old
 * URL-based signatures): drives the foreign room member through the old path
 * and asserts the detector DOES find the session in what it received. Skipped
 * on fixed code, where the old signature no longer exists.
 */
test("detector self-check: on the pre-fix URL code path the leak to a foreign agent IS detected", async (t) => {
  const api = await signedIn();
  if (!isPreFix(api)) {
    t.skip("pre-fix URL signature is gone (fixed code)");
    return;
  }
  const mark = agentLog.length;
  await driveEverything(api, "agt-foreign");
  const leaks = findLeaks(logFor(ports.foreign, mark));
  assert.ok(leaks.length > 0, "the old code path must leak and the detector must see it");
  assert.ok(leaks.some((l) => /\/eve\/v1\/(info|session)/.test(l)), `leaks: ${leaks.join(", ")}`);
});
