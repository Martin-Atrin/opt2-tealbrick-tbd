import test, { describe } from "node:test";
import assert from "node:assert/strict";
import { PassThrough } from "node:stream";
import { createInterface } from "node:readline";
import { connectMcp, type McpTool } from "@opt2-tealbrick/bridge";
import { KNOWLEDGE_MESSAGES, KNOWLEDGE_TOOL, idempotencyKey, documentArguments, knowledgeSave, type KnowledgeSaveDeps, type KnowledgeSaveInput } from "../src/main/knowledgeSave.ts";
import { relayLaunch } from "../src/main/relayLaunch.ts";
import type { AgentConnection } from "../src/main/agentIdentity.ts";

const connection: AgentConnection = {
  connectionId: "con_01JABCDEFGHJKMNPQRSTVWXYZ0", agentId: "agt_01JABCDEFGHJKMNPQRSTVWXYZ0", workspaceId: "ws_01JABCDEFGHJKMNPQRSTVWXYZ0",
  bridgeId: "brg_01JABCDEFGHJKMNPQRSTVWXYZ0", mcpUrl: "https://bridge.example/mcp", tokenEndpoint: "https://bridge.example/oauth/token", thumbprint: "kid1",
};

const input: KnowledgeSaveInput = {
  transcriptId: "0f6c1b2a-3d4e-4f50-8a9b-0c1d2e3f4a5b",
  title: "Weekly planning",
  body: "Source: https://www.youtube.com/watch?v=abc\nDate: 2026-10-12 09:30\nKind: Link\nDuration: 12:04\n\nHello team.",
  summary: "Link · 2026-10-12 09:30 · https://www.youtube.com/watch?v=abc",
  tags: ["planning", "team"],
};

interface Call { name: string; arguments: Record<string, unknown>; meta?: Record<string, unknown> }

/** A fake relay MCP server over in-process streams: a fixed tool list and scripted tools/call answers. */
function fakeRelay(tools: string[], answer: (call: Call, index: number) => unknown | undefined) {
  const toServer = new PassThrough();
  const toClient = new PassThrough();
  const calls: Call[] = [];
  createInterface({ input: toServer }).on("line", (line) => {
    const m = JSON.parse(line) as { id?: number; method: string; params?: Record<string, unknown> };
    if (typeof m.id !== "number") return;
    const reply = (result: unknown) => toClient.write(`${JSON.stringify({ jsonrpc: "2.0", id: m.id, result })}\n`);
    if (m.method === "initialize") reply({ protocolVersion: "2025-06-18" });
    else if (m.method === "tools/list") reply({ tools: tools.map((name): McpTool => ({ name, inputSchema: { type: "object" } })) });
    else if (m.method === "tools/call") {
      const call: Call = { name: m.params!.name as string, arguments: m.params!.arguments as Record<string, unknown>, meta: m.params!._meta as Record<string, unknown> | undefined };
      calls.push(call);
      const result = answer(call, calls.length - 1);
      if (result !== undefined) reply(result); // undefined: never answer (timeout case)
    }
  });
  let closed = 0;
  const open: KnowledgeSaveDeps["openRelay"] = async () => {
    const client = connectMcp({ streams: { input: toClient, output: toServer } });
    return { ...client, close: () => { closed += 1; } };
  };
  return { calls, open, closed: () => closed };
}

const created = { content: [{ type: "text", text: "{}" }], structuredContent: { id: "kdoc_01M4RFCA9YHB1037QX6VDTCFB0", area: "agt-tbd", version: 1 } };
const held = { content: [{ type: "text", text: "Waiting" }], structuredContent: { status: "held", holdId: "hold_1", expiresAt: new Date(Date.now() + 3_600_000).toISOString(), checkWith: "knowledge__tb_hold_status" }, isError: false };
const holdStatus = (status: string) => ({ content: [{ type: "text", text: status }], structuredContent: { status } });

test("granted tool: exact tool name, exact arguments, exact idempotency key, returns the document id", async () => {
  const relay = fakeRelay(["knowledge__recall", KNOWLEDGE_TOOL, "knowledge__tb_skills"], () => created);
  const result = await knowledgeSave(input, { connection: () => connection, openRelay: relay.open });
  assert.deepEqual(result, { documentId: "kdoc_01M4RFCA9YHB1037QX6VDTCFB0", area: "agt-tbd" });
  assert.equal(KNOWLEDGE_TOOL, "knowledge__document_create");
  assert.equal(relay.calls.length, 1);
  assert.equal(relay.calls[0].name, "knowledge__document_create");
  assert.deepEqual(relay.calls[0].arguments, {
    title: "Weekly planning",
    body: "Source: https://www.youtube.com/watch?v=abc\nDate: 2026-10-12 09:30\nKind: Link\nDuration: 12:04\n\nHello team.",
    summary: "Link · 2026-10-12 09:30 · https://www.youtube.com/watch?v=abc",
    tags: ["planning", "team"],
  });
  const key = idempotencyKey(input.transcriptId, documentArguments(input));
  assert.match(key, /^tbd-knowledge-0f6c1b2a-3d4e-4f50-8a9b-0c1d2e3f4a5b-[0-9a-f]{32}$/);
  assert.deepEqual(relay.calls[0].meta, { "tealbrick/idempotencyKey": key });
  assert.ok(key.length >= 8 && key.length <= 128);
  assert.equal(relay.closed(), 1, "the relay client is closed after the save");
});

test("the same transcript saved twice uses the same key; a changed title uses another", async () => {
  const relay = fakeRelay([KNOWLEDGE_TOOL], () => created);
  const deps = { connection: () => connection, openRelay: relay.open };
  await knowledgeSave(input, deps);
  await knowledgeSave({ ...input, tags: [" planning ", "team", "team"] }, deps); // normalised to the same arguments
  assert.equal(relay.calls.length, 2);
  assert.deepEqual(relay.calls[0].meta, relay.calls[1].meta);
  assert.notEqual(idempotencyKey(input.transcriptId, documentArguments({ ...input, title: "Other" })), relay.calls[0].meta?.["tealbrick/idempotencyKey"]);
});

test("tool not in the relay's list (not granted): exact no-grant message, no call", async () => {
  const relay = fakeRelay(["knowledge__recall", "kanban__issues_list"], () => created);
  await assert.rejects(knowledgeSave(input, { connection: () => connection, openRelay: relay.open }), {
    message: "TBD's agent has no Knowledge access. In Portal, open your workspace, draw a line from TBD's agent to Knowledge, choose Create, then press Connect.",
  });
  assert.equal(relay.calls.length, 0);
});

test("a grant removed between list and call (unknown_tool) gives the same no-grant message", async () => {
  const relay = fakeRelay([KNOWLEDGE_TOOL], () => ({ content: [{ type: "text", text: "x" }], structuredContent: { error: { code: "unknown_tool", message: "", requestId: "r" } }, isError: true }));
  await assert.rejects(knowledgeSave(input, { connection: () => connection, openRelay: relay.open }), { message: KNOWLEDGE_MESSAGES.noGrant });
});

test("agent not connected: exact message, the relay is never opened", async () => {
  let opened = false;
  await assert.rejects(
    knowledgeSave(input, { connection: () => null, openRelay: async () => { opened = true; throw new Error("unreachable"); } }),
    { message: "Connect TBD's agent to your workspace first (Chat › agent panel › Connect)." },
  );
  assert.equal(opened, false);
});

test("timeout: a call the relay never answers ends with the exact error", async () => {
  const relay = fakeRelay([KNOWLEDGE_TOOL], () => undefined);
  await assert.rejects(knowledgeSave(input, { connection: () => connection, openRelay: relay.open, rpcTimeoutMs: 100 }), {
    message: "Knowledge did not answer in time. Try again.",
  });
  assert.equal(relay.closed(), 1);
});

test("an app error is passed on in plain words", async () => {
  const relay = fakeRelay([KNOWLEDGE_TOOL], () => ({ content: [{ type: "text", text: "x" }], structuredContent: { error: { code: "input_invalid", message: "title too long", requestId: "r" } }, isError: true }));
  await assert.rejects(knowledgeSave(input, { connection: () => connection, openRelay: relay.open }), { message: "Knowledge did not save the document: title too long" });
});

// pollHold waits at least 10 s per check (CLI.md §7); the two hold cases run side by side.
describe("holds", { concurrency: 2 }, () => {
  test("held → approved: waiting status, then the exact same call is repeated once", async () => {
    const relay = fakeRelay([KNOWLEDGE_TOOL], (call, i) => (call.name === "knowledge__tb_hold_status" ? holdStatus("approved") : i === 0 ? held : created));
    const status: string[] = [];
    const result = await knowledgeSave(input, { connection: () => connection, openRelay: relay.open, onStatus: (m) => status.push(m) });
    assert.deepEqual(result, { documentId: "kdoc_01M4RFCA9YHB1037QX6VDTCFB0", area: "agt-tbd" });
    assert.deepEqual(status, ["Waiting for owner approval"]);
    assert.deepEqual(relay.calls.map((c) => c.name), ["knowledge__document_create", "knowledge__tb_hold_status", "knowledge__document_create"]);
    assert.deepEqual(relay.calls[1].arguments, { holdId: "hold_1" });
    assert.deepEqual(relay.calls[2].arguments, relay.calls[0].arguments);
    assert.deepEqual(relay.calls[2].meta, relay.calls[0].meta);
  });

  test("held → denied: exact message, no second create", async () => {
    const relay = fakeRelay([KNOWLEDGE_TOOL], (call) => (call.name === "knowledge__tb_hold_status" ? holdStatus("denied") : held));
    await assert.rejects(knowledgeSave(input, { connection: () => connection, openRelay: relay.open }), { message: "The owner declined saving this to Knowledge." });
    assert.deepEqual(relay.calls.map((c) => c.name), ["knowledge__document_create", "knowledge__tb_hold_status"]);
  });
});

test("held past the wait limit: still-waiting message (a later save repeats the same key)", async () => {
  const relay = fakeRelay([KNOWLEDGE_TOOL], () => held);
  await assert.rejects(knowledgeSave(input, { connection: () => connection, openRelay: relay.open, holdWaitMs: 50 }), {
    message: "Still waiting for owner approval. Save again after the owner approves.",
  });
  assert.equal(relay.calls.length, 1);
});

test("the person token never reaches this path: the relay env is allow-listed agent identity only", () => {
  process.env.TBD_FAKE_PORTAL_TOKEN = "tbo_should_not_leak";
  process.env.TBD_PORTAL_URL = "https://portal.example";
  try {
    const launch = relayLaunch(connection, { node: "/usr/bin/node", entry: "/res/relay.mjs", socketPath: "/data/agent-signer.sock", home: "/home/x" });
    assert.deepEqual(launch, {
      command: "/usr/bin/node",
      args: ["/res/relay.mjs"],
      env: {
        PATH: "/usr/bin:/bin",
        HOME: "/home/x",
        TB_SIGNER_SOCKET: "/data/agent-signer.sock",
        TB_BRIDGE_URL: "https://bridge.example",
        TB_CONNECTION_ID: "con_01JABCDEFGHJKMNPQRSTVWXYZ0",
        TB_AGENT_ID: "agt_01JABCDEFGHJKMNPQRSTVWXYZ0",
        TB_BRIDGE_ID: "brg_01JABCDEFGHJKMNPQRSTVWXYZ0",
      },
    });
    const leaked = Object.entries(launch.env).filter(([k, v]) => /portal|token|session|person/i.test(k) || /tbo_|portal/i.test(v));
    assert.deepEqual(leaked, [], "no portal/token variables reach the relay");
    // The module's inputs carry no person session: only the request, the connection and a relay opener.
    const deps: KnowledgeSaveDeps = { connection: () => connection, openRelay: async () => { throw new Error("x"); } };
    assert.deepEqual(Object.keys(deps).sort(), ["connection", "openRelay"]);
  } finally {
    delete process.env.TBD_FAKE_PORTAL_TOKEN;
    delete process.env.TBD_PORTAL_URL;
  }
});
