import test from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync, existsSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { generateKeyPairSync, sign as edSign, verify as edVerify, createPublicKey } from "node:crypto";
import { build } from "esbuild";
import { startSignerSocket, acceptableAssertionInput } from "../src/main/signerSocket.ts";
import { jwkThumbprint, type AgentConnection, type AgentSigner, type Ed25519Jwk } from "../src/main/agentIdentity.ts";

const b64 = (o: unknown) => Buffer.from(JSON.stringify(o)).toString("base64url");

function connection(thumb: string, bridgeOrigin = "https://bridge.example"): AgentConnection {
  return { connectionId: "con_01JABCDEFGHJKMNPQRSTVWXYZ0", agentId: "agt_01JABCDEFGHJKMNPQRSTVWXYZ0", workspaceId: "ws_01JABCDEFGHJKMNPQRSTVWXYZ0", bridgeId: "brg_01JABCDEFGHJKMNPQRSTVWXYZ0", mcpUrl: `${bridgeOrigin}/mcp`, tokenEndpoint: `${bridgeOrigin}/oauth/token`, thumbprint: thumb };
}

test("signer socket signs only agent assertions for this agent, connection and bridge", () => {
  const c = connection("kid1");
  const now = Math.floor(Date.now() / 1000);
  const good = { iss: "tb:agt:agt_01JABCDEFGHJKMNPQRSTVWXYZ0", sub: "tb:agt:agt_01JABCDEFGHJKMNPQRSTVWXYZ0", aud: "tb:brg:brg_01JABCDEFGHJKMNPQRSTVWXYZ0", con: "con_01JABCDEFGHJKMNPQRSTVWXYZ0", iat: now, exp: now + 60, jti: "x" };
  const hdr = { alg: "EdDSA", typ: "tb-agent-assert+jwt", kid: "kid1" };
  assert.equal(acceptableAssertionInput(`${b64(hdr)}.${b64(good)}`, c, now), true);
  assert.equal(acceptableAssertionInput(`${b64({ ...hdr, typ: "tb-owner-assert+jwt" })}.${b64(good)}`, c, now), false, "other typ");
  assert.equal(acceptableAssertionInput(`${b64(hdr)}.${b64({ ...good, aud: "tb:portal" })}`, c, now), false, "other audience");
  assert.equal(acceptableAssertionInput(`${b64(hdr)}.${b64({ ...good, sub: "tb:per:per_1" })}`, c, now), false, "person subject");
  assert.equal(acceptableAssertionInput(`${b64(hdr)}.${b64({ ...good, exp: now + 3600 })}`, c, now), false, "long-lived");
  assert.equal(acceptableAssertionInput(`${b64(hdr)}.${b64(good)}.sig`, c, now), false, "already signed / three parts");
  assert.equal(acceptableAssertionInput(`${b64({ ...hdr, kid: "other" })}.${b64(good)}`, c, now), false, "other key");
});

test("relay (bridge package) authenticates as the agent through the signer socket and forwards MCP", async () => {
  const dir = mkdtempSync(join(tmpdir(), "tbd-relay-"));
  const { privateKey } = generateKeyPairSync("ed25519");
  const jwk = createPublicKey(privateKey).export({ format: "jwk" }) as Ed25519Jwk;
  const signer: AgentSigner = {
    create: async () => jwk, publicJwk: async () => jwk,
    sign: async (_l, input) => edSign(null, Buffer.from(input), privateKey).toString("base64url"),
    rename: async () => {}, remove: async () => {},
  };
  const seen: { path: string; auth?: string }[] = [];
  const bridge = createServer((req, res) => {
    let raw = "";
    req.on("data", (c) => (raw += c));
    req.on("end", () => {
      seen.push({ path: req.url!, auth: req.headers.authorization });
      if (req.url === "/oauth/token") {
        const assertion = new URLSearchParams(raw).get("assertion")!;
        const [h, p, s] = assertion.split(".");
        const ok = edVerify(null, Buffer.from(`${h}.${p}`), createPublicKey({ key: jwk as never, format: "jwk" }), Buffer.from(s, "base64url"));
        res.writeHead(ok ? 200 : 401, { "content-type": "application/json" });
        res.end(JSON.stringify(ok ? { access_token: "k5", token_type: "Bearer", expires_in: 900 } : { error: "invalid_grant" }));
        return;
      }
      if (req.url === "/mcp" && req.method === "POST") {
        const msg = JSON.parse(raw);
        res.writeHead(200, { "content-type": "application/json", "mcp-session-id": "s1" });
        res.end(JSON.stringify({ jsonrpc: "2.0", id: msg.id, result: { protocolVersion: "2025-06-18", capabilities: {}, serverInfo: { name: "fake-bridge", version: "0" } } }));
        return;
      }
      res.writeHead(404); res.end();
    });
  });
  await new Promise<void>((r) => bridge.listen(0, "127.0.0.1", r));
  const origin = `http://127.0.0.1:${(bridge.address() as AddressInfo).port}`;
  const c = connection(jwkThumbprint(jwk), origin);
  const sock = join(dir, "signer.sock");
  const server = await startSignerSocket(sock, () => c, signer);
  assert.equal(statSync(sock).mode & 0o777, 0o600);
  const bundle = join(dir, "relay.mjs");
  await build({ entryPoints: ["src/agent/relay.ts"], outfile: bundle, bundle: true, platform: "node", format: "esm", logLevel: "error",
    banner: { js: "import { createRequire as __r } from 'node:module'; const require = __r(import.meta.url);" } });
  const child = spawn(process.execPath, [bundle], { env: { PATH: "/usr/bin:/bin", TB_SIGNER_SOCKET: sock, TB_BRIDGE_URL: origin, TB_CONNECTION_ID: "con_01JABCDEFGHJKMNPQRSTVWXYZ0", TB_AGENT_ID: "agt_01JABCDEFGHJKMNPQRSTVWXYZ0", TB_BRIDGE_ID: "brg_01JABCDEFGHJKMNPQRSTVWXYZ0" }, stdio: ["pipe", "pipe", "pipe"] });
  let stderr = "";
  child.stderr.on("data", (d) => (stderr += d));
  try {
    const lines = createInterface({ input: child.stdout });
    const reply = new Promise<any>((resolve) => lines.once("line", (l) => resolve(JSON.parse(l))));
    child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "t", version: "0" } } })}\n`);
    const r = await Promise.race([reply, new Promise((_, rej) => setTimeout(() => rej(new Error(`timeout; stderr: ${stderr}`)), 15000))]);
    assert.equal((r as any).result?.serverInfo?.name, "fake-bridge", `reply: ${JSON.stringify(r)} stderr: ${stderr} seen: ${JSON.stringify(seen)}`);
    assert.ok(seen.some((s) => s.path === "/oauth/token"), "agent assertion exchanged");
    assert.ok(seen.filter((s) => s.path === "/mcp").every((s) => s.auth === "Bearer k5"), "MCP carries only the agent's K5");
  } finally {
    child.kill(); server.close(); bridge.close();
    rmSync(dir, { recursive: true, force: true });
    assert.equal(existsSync(sock), false);
  }
});
