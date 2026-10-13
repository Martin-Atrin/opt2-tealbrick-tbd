import test from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import { createDefaultAgent } from "../src/main/defaultAgent.ts";
import { TBD_TOOLS, tbdAgentInfo } from "../src/main/tbdAgentInfo.ts";
import { drawerView, profileMenuLabel } from "../src/renderer/src/lib/workspaceAgents.ts";
import { RESTARTED, restartFailed } from "../src/renderer/src/lib/agentModel.ts";

/** Small fixes from the PARITY re-check: TBD's tools and model in the panel and menus, Restart, workspace profile. */

const bundled = await build({ entryPoints: ["src/renderer/src/lib/agentInfo.ts"], bundle: true, platform: "node", format: "esm", write: false });
const { summarize } = await import(`data:text/javascript;base64,${Buffer.from(bundled.outputFiles[0]!.text).toString("base64")}`);

test("TBD's manifest keeps its tools for the panel and the @ and / menus, and names the agent model", () => {
  const x = summarize(tbdAgentInfo("claude-opus-5-5"));
  assert.equal(x.native, true);
  assert.deepEqual(x.tools, TBD_TOOLS.map((t) => ({ name: t.name, description: t.description })));
  assert.deepEqual(x.tools.map((t: { name: string }) => t.name), ["Companion timeline", "Listening"]);
  assert.match(x.model, /claude-opus-5-5$/);
});

test("no model set: the manifest has no model, so the panel does not invent one", () => {
  const info = tbdAgentInfo(null);
  assert.equal("model" in info, false);
  assert.equal(summarize(info).model, undefined);
});

test("a workspace agent's drawer is always its read-only profile; TBD keeps its own views", () => {
  const remote = { workspace: { purpose: "p", state: "online" as const, harness: null } };
  assert.equal(drawerView(remote, "settings"), "workspace-profile");
  assert.equal(drawerView(remote, "overview"), "workspace-profile");
  assert.equal(drawerView({}, "settings"), "settings");
  assert.equal(drawerView(undefined, "overview"), "overview");
  assert.equal(profileMenuLabel(remote), "View Profile");
  assert.equal(profileMenuLabel({}), "Edit Profile");
});

test("restart messages", () => {
  assert.equal(RESTARTED, "TBD's agent restarted.");
  assert.equal(restartFailed(new Error("Error invoking remote method 'studio:restartAgent': Error: No model set for TBD's agent. Set up a model in Settings → Models.")),
    "Restart failed: No model set for TBD's agent. Set up a model in Settings → Models.");
  assert.equal(restartFailed(new Error("")), "Restart failed: the agent did not start");
});

test("restart stops the agent process and starts a new one that answers", async () => {
  const entry = fileURLToPath(new URL("./fixtures/fake-agent.ts", import.meta.url));
  let starts = 0;
  const agent = createDefaultAgent({
    node: process.execPath, entry,
    model: async () => { starts++; return { model: "m", apiKey: "sk-test" }; },
    config: async () => ({ cwd: "/tmp", stateDir: "/tmp/tbd-agent-test" }),
    permission: async () => ({ allow: true }),
  });
  try {
    await agent.sendTurn({ text: "one", onDelta: () => {}, onActivity: () => {} });
    assert.equal(starts, 1);
    await agent.restart();
    assert.equal(starts, 2);
    assert.equal(agent.running(), true);
    const r = await agent.sendTurn({ text: "two", onDelta: () => {}, onActivity: () => {} });
    assert.equal(r.reply.split("|")[0], "two");
    assert.equal(starts, 2, "the restarted process serves the next turn");
  } finally { agent.stop(); }
});

test("restart with no model reports the reason instead of hanging", async () => {
  const entry = fileURLToPath(new URL("./fixtures/fake-agent.ts", import.meta.url));
  const agent = createDefaultAgent({
    node: process.execPath, entry,
    model: async () => { throw new Error("No model set for TBD's agent. Set up a model in Settings → Models."); },
    config: async () => ({ cwd: "/tmp", stateDir: "/tmp/tbd-agent-test" }),
    permission: async () => ({ allow: true }),
  });
  await assert.rejects(agent.restart(), /No model set/);
  assert.equal(agent.running(), false);
});
