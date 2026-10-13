import type { AgentConnection } from "./agentIdentity";

/**
 * How the local relay (C5) is started for TBD's AGENT identity: the bundled relay entry, the K4
 * signer socket and the connection ids — nothing else. One definition for every caller (the default
 * agent's `tealbrick` MCP server and the Listening "Save to Knowledge" path), so both reach the
 * bridge the same way. The environment is allow-listed: the person token (K3), Portal URLs and the
 * helper's own environment never reach the relay (CREDENTIALS §12).
 */
export interface RelayLaunch {
  command: string;
  args: string[];
  env: Record<string, string>;
}

export function relayLaunch(c: AgentConnection, opts: { node: string; entry: string; socketPath: string; home: string }): RelayLaunch {
  return {
    command: opts.node,
    args: [opts.entry],
    env: {
      PATH: "/usr/bin:/bin",
      HOME: opts.home,
      TB_SIGNER_SOCKET: opts.socketPath,
      TB_BRIDGE_URL: new URL(c.mcpUrl).origin,
      TB_CONNECTION_ID: c.connectionId,
      TB_AGENT_ID: c.agentId,
      TB_BRIDGE_ID: c.bridgeId,
    },
  };
}
