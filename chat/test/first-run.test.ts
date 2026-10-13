import { test } from "node:test";
import assert from "node:assert/strict";
import { firstRunSteps, showFirstRun } from "../src/renderer/src/lib/firstRun.ts";

/** PARITY WP5: Chat's first-run checks name what is missing and the control that fixes it. */

test("no model: the model step is open with the native note and the Settings → Models action", () => {
  const steps = firstRunSteps({ model: { ready: false, note: "TBD's agent needs an Anthropic connection with an API key in Settings → Models." }, agentConnected: false });
  assert.deepEqual(steps.map((s) => [s.id, s.done, s.action ?? null]), [["signin", true, null], ["model", false, "models"], ["connect", false, "connect"]]);
  assert.equal(steps[1].detail, "TBD's agent needs an Anthropic connection with an API key in Settings → Models.");
  // The agent cannot answer: shown even in a conversation with history.
  assert.equal(showFirstRun(steps, false), true);
});

test("model ready, not connected: shown only in an empty conversation (the connection is optional)", () => {
  const steps = firstRunSteps({ model: { ready: true }, agentConnected: false });
  assert.deepEqual(steps.map((s) => [s.id, s.done]), [["signin", true], ["model", true], ["connect", false]]);
  assert.equal(steps[2].optional, true);
  assert.equal(showFirstRun(steps, true), true);
  assert.equal(showFirstRun(steps, false), false);
});

test("everything done: no checklist", () => {
  const steps = firstRunSteps({ model: { ready: true }, agentConnected: true });
  assert.equal(steps.every((s) => s.done), true);
  assert.equal(showFirstRun(steps, true), false);
});

test("a missing note falls back to the plain instruction", () => {
  assert.equal(firstRunSteps({ model: { ready: false }, agentConnected: true })[1].detail, "Choose a model for TBD's agent in Settings → Models.");
});
