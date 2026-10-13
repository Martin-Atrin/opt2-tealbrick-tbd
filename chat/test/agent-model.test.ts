import { test } from "node:test";
import assert from "node:assert/strict";
import { NO_AGENT_NOTE, NO_MODEL_TITLE, SET_UP_MODEL, TBD_AGENT_ID, modelGate, notSentReply } from "../src/renderer/src/lib/agentModel.ts";
import { NO_MODEL_NOTE, agentModelReadiness, requireAgentModel } from "../src/main/agentModelGuard.ts";
import { DEFAULT_AGENT_ID } from "../src/main/defaultAgent.ts";

/** "No model set": TBD's agent without a model never takes a message silently. */

const nativeNote = "No model set for TBD's agent. Set up a model in Settings → Models.";

test("the renderer and the helper name the same agent", () => {
  assert.equal(TBD_AGENT_ID, DEFAULT_AGENT_ID);
});

test("no model: TBD's agent is blocked with the native note and the set-up button text", () => {
  assert.deepEqual(modelGate(TBD_AGENT_ID, { ready: false, note: nativeNote }), { blocked: true, note: nativeNote });
  assert.equal(NO_MODEL_TITLE, "No model set");
  assert.equal(SET_UP_MODEL, "Set up a model");
  // A blank note still says what to do.
  assert.equal(modelGate(TBD_AGENT_ID, { ready: false, note: " " }).note, "TBD's agent needs a model before it can answer. Set up a model in Settings → Models.");
});

test("model ready, not checked yet, or another agent: not blocked", () => {
  assert.deepEqual(modelGate(TBD_AGENT_ID, { ready: true }), { blocked: false });
  assert.deepEqual(modelGate(TBD_AGENT_ID, null), { blocked: false });
  assert.deepEqual(modelGate("someone-else", { ready: false, note: nativeNote }), { blocked: false });
});

test("a message that is not sent gets a reply saying so", () => {
  assert.equal(notSentReply(nativeNote), `Not sent: ${nativeNote}`);
  assert.match(notSentReply(undefined), /^Not sent: .*Set up a model in Settings → Models\.$/);
});

test("helper guard: refuses a send with the plain native sentence when the model check fails", async () => {
  const failing = async () => { throw new Error(`Error invoking remote method 'native': Error: ${nativeNote}`); };
  await assert.rejects(requireAgentModel(failing), (e: Error) => e.message === nativeNote);
  assert.deepEqual(await agentModelReadiness(failing), { ready: false, note: nativeNote });
  // A failure with no text still names the step.
  await assert.rejects(requireAgentModel(async () => { throw new Error(""); }), (e: Error) => e.message === NO_MODEL_NOTE);
});

test("helper guard: passes when the model check passes", async () => {
  await assert.doesNotReject(requireAgentModel(async () => null));
  assert.deepEqual(await agentModelReadiness(async () => null), { ready: true });
});

test("the empty-roster advice names the TBD step, not a Portal canvas", () => {
  assert.doesNotMatch(NO_AGENT_NOTE, /portal|canvas|bind/i);
  assert.equal(NO_AGENT_NOTE, "TBD's agent did not load. Quit and reopen TBD. If it is still missing, update TBD.");
});
