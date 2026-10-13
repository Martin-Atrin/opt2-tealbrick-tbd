import test from "node:test";
import assert from "node:assert/strict";
import { build } from "esbuild";
import { createRequire } from "node:module";
import vm from "node:vm";

/** C127 in the Chat store: workspace rows mapped, notice kept non-blocking, refresh on focus and every 60 s. */

const bundle = await build({ entryPoints: ["src/renderer/src/lib/store.ts"], bundle: true, platform: "node", format: "cjs", packages: "external", tsconfig: "tsconfig.web.json", write: false });

const tbdRow = { id: "tbd-default", name: "TBD", runtime: "tbd-default", url: "local://tbd", accessMode: "private", audience: null, hasUrl: true, reachable: true, daemonLabel: null, peers: [], profile: null };
const remoteRow = (id: string, state: string) => ({
  id, name: `Agent ${id}`, runtime: "workspace", url: null, accessMode: "full", audience: null, hasUrl: false, reachable: state === "online",
  daemonLabel: null, peers: [], profile: null, workspace: { purpose: `Purpose ${id}`, state, harness: "Claude Code" },
});

function fixture(rows: () => unknown[]) {
  const focus: (() => void)[] = [];
  const intervals: { fn: () => void; ms: number }[] = [];
  let lists = 0;
  const directory = { accountId: "a", organizationId: "o", selectedId: "one", workspaces: [{ id: "one", name: "One" }] };
  const api = new Proxy({
    controlPlanes: async () => ({ activeId: "hosted", profiles: [{ id: "hosted", issuer: "https://portal.example" }] }),
    session: async () => ({ email: "fixture@example.test" }), portalWorkspaces: async () => directory,
    listAgents: async () => { lists++; return rows(); },
    loadState: async () => null, saveState: async () => {}, selectPortalWorkspace: async () => {},
    agentHealth: async () => true, firstRun: async () => ({ model: { ready: true }, agentConnected: false }),
  } as Record<string, unknown>, { get: (target, key: string) => target[key] ?? (() => Promise.resolve(null)) });
  const module = { exports: {} as Record<string, any> };
  vm.runInNewContext(bundle.outputFiles[0]!.text, {
    module, exports: module.exports, require: createRequire(import.meta.url), console, Error, AbortController, setTimeout, clearTimeout,
    window: { studio: api, addEventListener: (name: string, fn: () => void) => { if (name === "focus") focus.push(fn); } },
    document: { addEventListener: () => {}, visibilityState: "hidden", hasFocus: () => false },
    setInterval: (fn: () => void, ms: number) => { intervals.push({ fn, ms }); return 0; }, clearInterval: () => {},
  });
  return { store: module.exports.useStore, focus, intervals, lists: () => lists };
}

test("workspace rows: card state as status, purpose as preview, TBD stays first and active", async () => {
  const f = fixture(() => [tbdRow, remoteRow("agt_a", "online"), remoteRow("agt_b", "paused")]);
  await f.store.getState().bootstrap();
  await f.store.getState().refreshAgents();
  const s = f.store.getState();
  assert.deepEqual(s.agents.map((a: any) => [a.id, a.status, a.workspace?.state ?? null]), [["tbd-default", "online", null], ["agt_a", "online", "online"], ["agt_b", "offline", "paused"]]);
  assert.equal(s.agents[1].lastMessagePreview, "Purpose agt_a");
  assert.equal(s.activeAgentId, "tbd-default");
  assert.equal(s.rosterNotice, null);
});

test("a send to a workspace agent goes nowhere it cannot (no transport yet): nothing is added or sent", async () => {
  const f = fixture(() => [tbdRow, remoteRow("agt_a", "online")]);
  await f.store.getState().bootstrap();
  await f.store.getState().refreshAgents();
  f.store.getState().send("agt_a", "hi");
  assert.equal((f.store.getState().conversations["agt_a"] ?? []).length, 0);
});

test("Portal error notice: shown, TBD still usable, cleared by the next good refresh", async () => {
  let fail = true;
  const f = fixture(() => fail ? [{ ...tbdRow, rosterNotice: "The other agents of this workspace could not be loaded (x). TBD tries again in a minute." }] : [tbdRow, remoteRow("agt_a", "offline")]);
  await f.store.getState().bootstrap();
  await f.store.getState().refreshAgents();
  assert.equal(f.store.getState().rosterNotice, "The other agents of this workspace could not be loaded (x). TBD tries again in a minute.");
  assert.equal(f.store.getState().authError, null);
  assert.deepEqual(f.store.getState().agents.map((a: any) => a.id), ["tbd-default"]);
  fail = false;
  await f.store.getState().refreshAgents();
  assert.equal(f.store.getState().rosterNotice, null);
  assert.deepEqual(f.store.getState().agents.map((a: any) => a.id), ["tbd-default", "agt_a"]);
});

test("refresh: on window focus and every 60 s, armed once", async () => {
  const f = fixture(() => [tbdRow]);
  await f.store.getState().bootstrap();
  await f.store.getState().refreshAgents();
  await f.store.getState().refreshAgents();
  const roster = f.intervals.filter((i) => i.ms === 60_000);
  assert.equal(roster.length, 1);
  const before = f.lists();
  for (const fn of f.focus) fn();
  roster[0]!.fn();
  await new Promise((r) => setTimeout(r, 10));
  assert.ok(f.lists() >= before + 2, `expected two more roster reads, got ${f.lists() - before}`);
});
