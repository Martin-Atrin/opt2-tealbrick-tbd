import test from "node:test";
import assert from "node:assert/strict";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import type { AgentCard, HarnessOptionList } from "@opt2-tealbrick/spec/routes";
import type { RemoteAgent } from "../src/shared/ipc.ts";
import { buildRoster, cardState, workspaceAgentRow } from "../src/main/workspaceAgents.ts";
import { createPortal, type PersonSession } from "../src/main/portal.ts";
import { CHAT_COMES_NEXT, stateLabel, workspaceAgentSubtitle } from "../src/renderer/src/lib/workspaceAgents.ts";

/** C127: TBD lists every agent of its Portal workspace (listing only; chat comes later). */

const tbd: RemoteAgent = {
  id: "tbd-default", name: "TBD", runtime: "tbd-default", url: "local://tbd", accessMode: "private", audience: null,
  hasUrl: true, reachable: true, daemonLabel: null, peers: [], profile: null,
};

function card(id: string, over: Partial<AgentCard> = {}): AgentCard {
  return {
    id: id as AgentCard["id"], ws: "ws_1" as AgentCard["ws"], name: `Agent ${id}`, purpose: `Purpose ${id}`,
    harnessOptionId: "claude-code", endpointLabel: null, mode: "full" as AgentCard["mode"], status: "connected",
    paused: false, connections: 1, createdBy: "owner", createdAt: "2026-10-13T00:00:00Z" as AgentCard["createdAt"], ...over,
  };
}
const harness: HarnessOptionList = {
  items: [{ id: "claude-code", kind: "desktop", label: "Claude Code", icon: null, authorise: "device_approval", noAgentPath: false }],
};

test("card state: connected is online, pending and authorised are offline, paused wins", () => {
  assert.equal(cardState({ status: "connected", paused: false }), "online");
  assert.equal(cardState({ status: "pending", paused: false }), "offline");
  assert.equal(cardState({ status: "authorised", paused: false }), "offline");
  assert.equal(cardState({ status: "paused", paused: false }), "paused");
  assert.equal(cardState({ status: "connected", paused: true }), "paused");
});

test("row mapping: name, purpose, state and harness label; no chat address", () => {
  const row = workspaceAgentRow(card("agt_a"), harness);
  assert.deepEqual(
    { id: row.id, name: row.name, url: row.url, hasUrl: row.hasUrl, reachable: row.reachable, workspace: row.workspace },
    { id: "agt_a", name: "Agent agt_a", url: null, hasUrl: false, reachable: true, workspace: { purpose: "Purpose agt_a", state: "online", harness: "Claude Code" } },
  );
  // Unknown harness id: the id itself; no harness labels at all: the id; empty id: none.
  assert.equal(workspaceAgentRow(card("agt_b", { harnessOptionId: "custom" }), harness).workspace?.harness, "custom");
  assert.equal(workspaceAgentRow(card("agt_c"), null).workspace?.harness, "claude-code");
  assert.equal(workspaceAgentRow(card("agt_d", { harnessOptionId: "" }), harness).workspace?.harness, null);
});

test("roster: TBD first, then the workspace cards in Portal order, TBD's own card left out", async () => {
  const seen: string[] = [];
  const roster = await buildRoster({
    tbd, workspace: "ws_1", ownCardId: "agt_tbd",
    portal: {
      agents: async (ws) => { seen.push(ws); return [card("agt_b", { status: "pending" }), card("agt_tbd"), card("agt_a", { paused: true })]; },
      harnessOptions: async () => harness,
    },
  });
  assert.deepEqual(seen, ["ws_1"]);
  assert.deepEqual(roster.map((r) => [r.id, r.workspace?.state ?? null]), [["tbd-default", null], ["agt_b", "offline"], ["agt_a", "paused"]]);
  assert.equal(roster[0]?.rosterNotice, undefined);
});

test("not connected to a Portal workspace: only TBD's agent, no notice, no Portal call", async () => {
  let called = false;
  const portal = { agents: async () => { called = true; return []; }, harnessOptions: async () => harness };
  assert.deepEqual(await buildRoster({ tbd, workspace: null, portal }), [tbd]);
  assert.deepEqual(await buildRoster({ tbd, workspace: "ws_1", portal: null }), [tbd]);
  assert.equal(called, false);
});

test("Portal error: TBD's agent stays, with a non-blocking notice; harness failure only drops labels", async () => {
  const failed = await buildRoster({
    tbd, workspace: "ws_1",
    portal: { agents: async () => { throw new Error("Portal answered 503"); }, harnessOptions: async () => harness },
  });
  assert.equal(failed.length, 1);
  assert.equal(failed[0]?.id, "tbd-default");
  assert.equal(failed[0]?.rosterNotice, "The other agents of this workspace could not be loaded (Portal answered 503). TBD tries again in a minute.");
  const unlabeled = await buildRoster({
    tbd, workspace: "ws_1",
    portal: { agents: async () => [card("agt_a")], harnessOptions: async () => { throw new Error("down"); } },
  });
  assert.deepEqual(unlabeled.map((r) => r.workspace?.harness ?? null), [null, "claude-code"]);
  assert.equal(unlabeled[0]?.rosterNotice, undefined);
});

test("read-only view texts", () => {
  assert.equal(CHAT_COMES_NEXT, "Chat with this agent comes next.");
  assert.deepEqual((["online", "offline", "paused"] as const).map(stateLabel), ["Online", "Offline", "Paused"]);
  assert.equal(workspaceAgentSubtitle({ purpose: "p", state: "paused", harness: "Claude Code" }), "Paused · Claude Code");
  assert.equal(workspaceAgentSubtitle({ purpose: "p", state: "online", harness: null }), "Online");
});

test("Portal client: agents.list with the owner session, all pages, and harness options", async () => {
  const seen: { url: string; auth?: string }[] = [];
  const server = createServer((req: IncomingMessage, res: ServerResponse) => {
    seen.push({ url: req.url!, auth: req.headers.authorization });
    const send = (body: unknown) => { res.writeHead(200, { "content-type": "application/json" }); res.end(JSON.stringify(body)); };
    if (req.url === "/api/v1/workspaces/ws_1/agents?limit=200") return send({ items: [card("agt_a")], nextCursor: "c2" });
    if (req.url === "/api/v1/workspaces/ws_1/agents?limit=200&cursor=c2") return send({ items: [card("agt_b")], nextCursor: null });
    if (req.url === "/api/v1/harness-options") return send(harness);
    res.writeHead(404); res.end();
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  let session: PersonSession | null = { token: "tbo_a", sessionId: "osn_a", expiresAt: Date.now() + 60_000, email: null };
  const p = createPortal({ origin: `http://127.0.0.1:${(server.address() as AddressInfo).port}`, store: { load: () => session, save: (s) => { session = s; } }, machineLabel: "m" });
  try {
    assert.deepEqual((await p.agents("ws_1")).map((c) => c.id), ["agt_a", "agt_b"]);
    assert.equal((await p.harnessOptions()).items[0]?.label, "Claude Code");
    assert.deepEqual(seen.map((s) => s.auth), ["Bearer tbo_a", "Bearer tbo_a", "Bearer tbo_a"]);
  } finally { await new Promise<void>((r) => server.close(() => r())); }
});
