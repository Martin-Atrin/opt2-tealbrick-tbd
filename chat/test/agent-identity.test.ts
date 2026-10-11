import test from "node:test";
import assert from "node:assert/strict";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { generateKeyPairSync, sign as edSign, verify as edVerify, createPublicKey, type KeyObject } from "node:crypto";
import { createAgentIdentity, jwkThumbprint, type AgentConnection, type AgentSigner, type Ed25519Jwk } from "../src/main/agentIdentity.ts";

/** In-memory stand-in for the Keychain signer: same interface, real Ed25519. */
function fakeSigner() {
  const keys = new Map<string, KeyObject>();
  const signer: AgentSigner = {
    async create(label) {
      if (keys.has(label)) throw Error("exists");
      const { privateKey } = generateKeyPairSync("ed25519");
      keys.set(label, privateKey);
      return createPublicKey(privateKey).export({ format: "jwk" }) as Ed25519Jwk;
    },
    async publicJwk(label) { return createPublicKey(keys.get(label)!).export({ format: "jwk" }) as Ed25519Jwk; },
    async sign(label, input) { return edSign(null, Buffer.from(input), keys.get(label)!).toString("base64url"); },
    async rename(from, to) { keys.set(to, keys.get(from)!); keys.delete(from); },
    async remove(label) { keys.delete(label); },
  };
  return { signer, keys };
}

function memoryStore() {
  let value: AgentConnection | null = null;
  return { load: () => value, save: (c: AgentConnection | null) => { value = c; } };
}

async function server(handler: (req: IncomingMessage, raw: string, res: ServerResponse) => void) {
  const seen: { url: string; raw: string; auth?: string }[] = [];
  const s = createServer((req, res) => {
    let raw = "";
    req.on("data", (c) => (raw += c));
    req.on("end", () => { seen.push({ url: req.url!, raw, auth: req.headers.authorization }); handler(req, raw, res); });
  });
  await new Promise<void>((r) => s.listen(0, "127.0.0.1", r));
  return { origin: `http://127.0.0.1:${(s.address() as AddressInfo).port}`, seen, close: () => new Promise<void>((r) => s.close(() => r())) };
}
const json = (res: ServerResponse, status: number, body: unknown) => { res.writeHead(status, { "content-type": "application/json" }); res.end(JSON.stringify(body)); };

test("agent connection: tbd/agent device flow with tbd-default, key bound to con, K5 from a verified assertion", async () => {
  const { signer, keys } = fakeSigner();
  let publicKey: Ed25519Jwk | null = null;
  let tokenCalls = 0;
  const bridge = await server((req, raw, res) => {
    tokenCalls++;
    const form = new URLSearchParams(raw);
    assert.equal(form.get("grant_type"), "urn:ietf:params:oauth:grant-type:jwt-bearer");
    const [h, p, sig] = form.get("assertion")!.split(".");
    const header = JSON.parse(Buffer.from(h, "base64url").toString());
    const claims = JSON.parse(Buffer.from(p, "base64url").toString());
    assert.equal(header.alg, "EdDSA"); assert.equal(header.typ, "tb-agent-assert+jwt");
    assert.equal(header.kid, jwkThumbprint(publicKey!));
    assert.equal(claims.iss, "tb:agt:agt_1"); assert.equal(claims.sub, "tb:agt:agt_1");
    assert.equal(claims.aud, "tb:brg:brg_1"); assert.equal(claims.con, "con_1");
    assert.ok(claims.exp - claims.iat <= 60); assert.match(claims.jti, /^[0-9A-HJKMNP-TV-Z]{26}$/);
    const ok = edVerify(null, Buffer.from(`${h}.${p}`), createPublicKey({ key: publicKey as never, format: "jwk" }), Buffer.from(sig, "base64url"));
    assert.ok(ok, "signature verifies with the registered public key");
    if (tokenCalls === 1) return json(res, 400, { error: "invalid_grant", error_description: "connection_unknown" });
    json(res, 200, { access_token: "k5_token", token_type: "Bearer", expires_in: 900 });
  });
  const portal = await server((req, raw, res) => {
    const body = JSON.parse(raw);
    if (req.url === "/api/v1/device/authorize") {
      assert.equal(body.scope, "agent"); assert.equal(body.client_id, "tbd"); assert.equal(body.harness, "tbd-default");
      assert.equal(body.agents.length, 1); assert.equal(body.agents[0].agt, undefined);
      publicKey = body.agents[0].public_key;
      return json(res, 200, { device_code: "tbdv_a", user_code: "U", verification_uri: "v", verification_uri_complete: "v?c", expires_in: 600, interval: 5 });
    }
    if (req.url === "/api/v1/device/token") {
      return json(res, 200, { scope: "agent", workspace_id: "ws_1", mcp_url: `${bridge.origin}/mcp`, token_endpoint: `${bridge.origin}/oauth/token`, connections: [{ connection_id: "con_1", agent_id: "agt_1", public_key_thumbprint: jwkThumbprint(publicKey!) }] });
    }
    json(res, 404, { error: { code: "not_found", message: "x", requestId: "r" } });
  });
  const store = memoryStore();
  const id = createAgentIdentity({ origin: portal.origin, machineLabel: "TBD on test", signer, store, bridgeIdFor: async () => "brg_1", sleep: async () => {} });
  try {
    await id.start();
    const c = await id.await();
    assert.equal(c.connectionId, "con_1");
    assert.ok(keys.has("con_1") && keys.size === 1, "pending key renamed to the connection id");
    assert.equal(await id.accessToken(), "k5_token");
    assert.equal(tokenCalls, 2, "connection_unknown is retried");
    assert.equal(await id.accessToken(), "k5_token");
    assert.equal(tokenCalls, 2, "K5 cached until near expiry");
    // No request carried any bearer: person credentials never involved.
    assert.ok([...portal.seen, ...bridge.seen].every((r) => r.auth === undefined));
    await id.disconnect();
    assert.equal(keys.size, 0); assert.equal(store.load(), null);
  } finally { await portal.close(); await bridge.close(); }
});

test("denied agent connection removes the pending key", async () => {
  const { signer, keys } = fakeSigner();
  const portal = await server((req, _raw, res) => {
    if (req.url === "/api/v1/device/authorize") return json(res, 200, { device_code: "d", user_code: "u", verification_uri: "v", verification_uri_complete: "v", expires_in: 600, interval: 1 });
    json(res, 400, { error: { code: "access_denied", message: "no", requestId: "r" } });
  });
  const id = createAgentIdentity({ origin: portal.origin, machineLabel: "m", signer, store: memoryStore(), bridgeIdFor: async () => "brg", sleep: async () => {} });
  try {
    await id.start();
    await assert.rejects(id.await(), /denied/);
    await id.start();
    assert.equal(keys.size, 1, "a restart replaces the previous pending key");
  } finally { await portal.close(); }
});
