import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { hostname } from "node:os";
import { join } from "node:path";
import { app, nativeCall, safeStorage } from "../tbd/host";
import { currentControlPlane } from "./controlPlanes";
import { createPortal, type PersonSession, type Portal } from "./portal";
import { createAgentIdentity, type AgentConnection, type AgentIdentity, type AgentSigner, type Ed25519Jwk } from "./agentIdentity";
import { createDefaultAgent, type DefaultAgent } from "./defaultAgent";
import { askPerson } from "./asks";
import { startSignerSocket } from "./signerSocket";
import type { Server } from "node:net";

/**
 * The helper's composition root: one Portal client (person, K3), one agent
 * identity (K4 in the Keychain via the host), one default agent process.
 * Built once per control plane; the person token never leaves `portal`.
 */

function dataDir(): string {
  const dir = app.getPath("userData");
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  return dir;
}

/** Person session, encrypted with the host's Keychain-held key. */
function personStore() {
  const file = () => join(dataDir(), "person.bin");
  let cache: PersonSession | null | undefined;
  return {
    load(): PersonSession | null {
      if (cache !== undefined) return cache;
      try {
        cache = existsSync(file()) && safeStorage.isEncryptionAvailable() ? (JSON.parse(safeStorage.decryptString(readFileSync(file()))) as PersonSession) : null;
      } catch { cache = null; }
      return cache;
    },
    save(s: PersonSession | null): void {
      cache = s;
      if (!s) { rmSync(file(), { force: true }); return; }
      if (safeStorage.isEncryptionAvailable()) writeFileSync(file(), safeStorage.encryptString(JSON.stringify(s)), { mode: 0o600 });
    },
  };
}

/** The approved connection record: ids and URLs only, no secret. */
function connectionStore() {
  const file = () => join(dataDir(), "agent-connection.json");
  return {
    load(): AgentConnection | null {
      try { return existsSync(file()) ? (JSON.parse(readFileSync(file(), "utf8")) as AgentConnection) : null; } catch { return null; }
    },
    save(c: AgentConnection | null): void {
      if (!c) rmSync(file(), { force: true });
      else writeFileSync(file(), JSON.stringify(c, null, 2), { mode: 0o600 });
    },
  };
}

/** K4 lives in the Keychain; the native host signs. */
export const keychainSigner: AgentSigner = {
  create: (label) => nativeCall("agentKeyCreate", label) as Promise<Ed25519Jwk>,
  publicJwk: (label) => nativeCall("agentKeyPublic", label) as Promise<Ed25519Jwk>,
  sign: (label, input) => nativeCall("agentKeySign", label, input) as Promise<string>,
  rename: async (from, to) => { await nativeCall("agentKeyRename", from, to); },
  remove: async (label) => { await nativeCall("agentKeyDelete", label); },
};

export function machineLabel(): string {
  const host = hostname().replace(/\.local$/, "").slice(0, 40);
  return `TBD on ${host || "this Mac"}`;
}

export interface Services {
  portal: Portal;
  agentIdentity: AgentIdentity;
  agent: DefaultAgent;
}

let services: Services | null = null;
let signerServer: Server | null = null;

export function getServices(): Services {
  if (services) return services;
  const origin = currentControlPlane().issuer;
  const portal = createPortal({ origin, store: personStore(), machineLabel: machineLabel() });
  const agentIdentity = createAgentIdentity({
    origin,
    machineLabel: machineLabel(),
    signer: keychainSigner,
    store: connectionStore(),
    // C26: until DeviceAgentTokenResult carries bridge_id, read it with the person session.
    bridgeIdFor: async (ws) => {
      const list = await portal.workspaces();
      const id = list.items.find((w) => w.id === ws)?.bridge.id;
      if (!id) throw new Error("The workspace has no bridge yet. Set up the workspace infrastructure in Portal first.");
      return id;
    },
  });
  const resources = process.env.TBD_RESOURCES ?? join(process.execPath, "..");
  const agent = createDefaultAgent({
    node: process.execPath,
    entry: join(resources, "agent.mjs"),
    model: async () => (await nativeCall("agentModel")) as { model: string; baseUrl?: string; apiKey: string },
    config: async () => {
      const c = agentIdentity.connection();
      let relay;
      if (c) {
        // K4 handle for the relay: signs agent assertions only (signerSocket.ts).
        const socketPath = join(dataDir(), "agent-signer.sock");
        if (!signerServer) signerServer = await startSignerSocket(socketPath, () => agentIdentity.connection(), keychainSigner);
        relay = {
          command: process.execPath,
          args: [join(resources, "relay.mjs")],
          env: {
            PATH: "/usr/bin:/bin",
            HOME: process.env.HOME ?? "",
            TB_SIGNER_SOCKET: socketPath,
            TB_BRIDGE_URL: new URL(c.mcpUrl).origin,
            TB_CONNECTION_ID: c.connectionId,
            TB_AGENT_ID: c.agentId,
            TB_BRIDGE_ID: c.bridgeId,
          },
        };
      }
      return {
        cwd: app.getPath("home"),
        stateDir: join(dataDir(), "agent"),
        claudeExecutable: join(resources, "claude"),
        companionCli: process.env.TBD_COMPANION_CLI,
        listeningCli: process.env.TBD_LISTENING_CLI,
        relay,
      };
    },
    ask: (a) => askPerson(a),
  });
  services = { portal, agentIdentity, agent };
  return services;
}

/** Workspace or account change: stop the agent, drop cached clients. */
export function resetServices(): void {
  services?.agent.stop();
  services = null;
  signerServer?.close();
  signerServer = null;
}
