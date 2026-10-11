import { createServer, type Server } from "node:net";
import { chmodSync, rmSync } from "node:fs";
import type { AgentConnection, AgentSigner, Ed25519Jwk } from "./agentIdentity";

/**
 * The K4 "handle" for the local relay (CREDENTIALS §12 b): a user-only Unix
 * socket in TBD's data folder. The relay (a child of the default agent) asks
 * for the public key and for signatures; the private key stays in the
 * Keychain. Only AGENT ASSERTIONS for this agent and this bridge are signed —
 * the socket cannot be used to sign anything else.
 */

const MAX_LINE = 16_384;

function b64json(part: string): Record<string, unknown> | null {
  try { return JSON.parse(Buffer.from(part, "base64url").toString("utf8")) as Record<string, unknown>; } catch { return null; }
}

/** Accept only `tb-agent-assert+jwt` for our agent, connection and bridge, short-lived. */
export function acceptableAssertionInput(input: string, c: AgentConnection, nowSec = Math.floor(Date.now() / 1000)): boolean {
  if (input.length > MAX_LINE || !/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(input)) return false;
  const [h, p] = input.split(".");
  const header = b64json(h);
  const claims = b64json(p);
  if (!header || !claims) return false;
  if (header.alg !== "EdDSA" || header.typ !== "tb-agent-assert+jwt" || header.kid !== c.thumbprint) return false;
  const agent = `tb:agt:${c.agentId}`;
  if (claims.iss !== agent || claims.sub !== agent || claims.con !== c.connectionId || claims.aud !== `tb:brg:${c.bridgeId}`) return false;
  const iat = Number(claims.iat), exp = Number(claims.exp);
  return Number.isFinite(iat) && Number.isFinite(exp) && exp > iat && exp - iat <= 60 && Math.abs(iat - nowSec) <= 120;
}

export function startSignerSocket(path: string, connection: () => AgentConnection | null, signer: AgentSigner): Promise<Server> {
  rmSync(path, { force: true });
  const server = createServer((socket) => {
    let buf = "";
    socket.setEncoding("utf8");
    socket.on("data", async (chunk: string) => {
      buf += chunk;
      if (buf.length > MAX_LINE * 2) { socket.destroy(); return; }
      let nl: number;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, nl); buf = buf.slice(nl + 1);
        let reply: Record<string, unknown>;
        try {
          const req = JSON.parse(line) as { op?: string; input?: string };
          const c = connection();
          if (!c) reply = { error: "not_connected" };
          else if (req.op === "jwk") reply = { jwk: (await signer.publicJwk(c.connectionId)) as Ed25519Jwk };
          else if (req.op === "sign" && typeof req.input === "string" && acceptableAssertionInput(req.input, c)) reply = { sig: await signer.sign(c.connectionId, req.input) };
          else reply = { error: "refused" };
        } catch { reply = { error: "bad_request" }; }
        socket.write(`${JSON.stringify(reply)}\n`);
      }
    });
    socket.on("error", () => socket.destroy());
  });
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(path, () => { chmodSync(path, 0o600); resolve(server); });
  });
}
