import { test } from "node:test";
import assert from "node:assert/strict";
import { agentCardModel, agentStatus, initialOf } from "../src/renderer/src/lib/agentCard.ts";

/** C146: the agent card reads existing data only. */

const base = { id: "a", name: "Research Scout", url: "", accent: "" };

test("workspace agent: harness from its card, status from its state", () => {
  const online = agentCardModel({ ...base, workspace: { purpose: "", state: "online", harness: "Claude Code" } });
  assert.deepEqual([online.initial, online.harness, online.status], ["R", "Claude Code", { kind: "live", text: "Online" }]);
  const paused = agentCardModel({ ...base, workspace: { purpose: "", state: "paused", harness: null } });
  assert.deepEqual([paused.harness, paused.status], [undefined, { kind: "idle", text: "Paused" }]);
});

test("TBD's own agent: harness from its info, no pill while its status is unknown", () => {
  assert.equal(agentCardModel(base, { harness: "tbd-default" }).harness, "tbd-default");
  assert.equal(agentStatus({ status: "unknown" }), undefined);
  assert.deepEqual(agentStatus({ status: "offline" }), { kind: "idle", text: "Not answering" });
});

test("a missing model or a turn in flight outranks the state", () => {
  assert.deepEqual(agentStatus({ status: "online" }, { modelBlocked: "No model set", busy: true }), { kind: "needs-you", text: "No model set" });
  assert.deepEqual(agentStatus({ status: "online" }, { busy: true }), { kind: "busy", text: "Working" });
});

test("no data names apps, so none are invented", () => {
  assert.deepEqual(agentCardModel(base).appIds, []);
  assert.equal(initialOf("  "), "?");
});
