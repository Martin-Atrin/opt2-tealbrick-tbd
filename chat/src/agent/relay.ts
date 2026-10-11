import { createConnection } from "node:net";
import { startRelay, manifestApi } from "@opt2-tealbrick/bridge";

/**
 * The local relay (C5) as the default agent's `tealbrick` MCP server (stdio).
 * Same @opt2-tealbrick/bridge package in relay form: identity only, no grants,
 * no checks — the deployed bridge decides everything. Authenticates upstream as
 * TBD's AGENT with K4 signatures obtained over the helper's signer socket.
 * It never sees the person credential.
 */

const env = (name: string): string => {
  const v = process.env[name];
  if (!v) { process.stderr.write(`relay: missing ${name}\n`); process.exit(2); }
  return v;
};

function call(socketPath: string, req: Record<string, unknown>): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    const s = createConnection(socketPath);
    let buf = "";
    s.setEncoding("utf8");
    s.on("data", (d: string) => {
      buf += d;
      const nl = buf.indexOf("\n");
      if (nl >= 0) { s.end(); try { resolve(JSON.parse(buf.slice(0, nl))); } catch (e) { reject(e); } }
    });
    s.on("error", reject);
    s.write(`${JSON.stringify(req)}\n`);
  });
}

const socket = env("TB_SIGNER_SOCKET");
const jwkReply = await call(socket, { op: "jwk" });
if (!jwkReply.jwk) { process.stderr.write(`relay: signer unavailable (${String(jwkReply.error)})\n`); process.exit(3); }
const jwk = jwkReply.jwk as never;

const relay = startRelay({
  api: manifestApi(),
  bridgeUrl: env("TB_BRIDGE_URL"),
  connection: { con: env("TB_CONNECTION_ID") as never, agt: env("TB_AGENT_ID") as never, bridgeId: env("TB_BRIDGE_ID") as `brg_${string}` },
  signer: {
    publicJwk: () => jwk,
    sign: async (input: string) => {
      const r = await call(socket, { op: "sign", input });
      if (typeof r.sig !== "string") throw new Error(`signer refused (${String(r.error)})`);
      return r.sig;
    },
  },
  onStatus: (status, detail) => process.stderr.write(`relay: ${status}${detail ? ` (${detail})` : ""}\n`),
});
await relay.done;
