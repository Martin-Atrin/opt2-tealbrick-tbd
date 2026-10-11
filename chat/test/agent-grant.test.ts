import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { NOT_GRANTED_MESSAGE, isAgentNotGranted, retryAfterGrantRefresh } from "../src/main/agentGrant.ts";

const denied = () => Object.assign(new Error("denied"), { status: 403, body: { error: "agent_not_granted" } });

test("403 agent_not_granted forces one refresh and retries once", async () => {
  let calls = 0, refreshes = 0;
  const result = await retryAfterGrantRefresh(
    async () => { if (++calls === 1) throw denied(); return "ok"; },
    async () => { refreshes++; return { token: "t" }; },
  );
  assert.equal(result, "ok");
  assert.equal(calls, 2);
  assert.equal(refreshes, 1);
});

test("a second 403 after refresh is surfaced, not retried again", async () => {
  let calls = 0, refreshes = 0;
  await assert.rejects(
    retryAfterGrantRefresh(async () => { calls++; throw denied(); }, async () => { refreshes++; return {}; }),
    (e) => e.status === 403,
  );
  assert.equal(calls, 2);
  assert.equal(refreshes, 1);
});

test("a failed refresh surfaces the original refusal without retrying", async () => {
  let calls = 0;
  await assert.rejects(retryAfterGrantRefresh(async () => { calls++; throw denied(); }, async () => null), (e) => e.status === 403);
  assert.equal(calls, 1);
});

test("other failures and successes never refresh", async () => {
  let refreshes = 0;
  const refresh = async () => { refreshes++; return {}; };
  assert.equal(await retryAfterGrantRefresh(async () => 1, refresh), 1);
  await assert.rejects(retryAfterGrantRefresh(async () => { throw Object.assign(new Error("x"), { status: 500, body: "" }); }, refresh));
  await assert.rejects(retryAfterGrantRefresh(async () => { throw new Error("network"); }, refresh));
  assert.equal(refreshes, 0);
});

test("HTML 403 (deployment protection) is not a grant problem", () => {
  assert.equal(isAgentNotGranted(403, "<!doctype html><html>"), false);
  assert.equal(isAgentNotGranted(403, '{"error":"agent_not_granted"}'), true);
  assert.equal(isAgentNotGranted(401, "agent_not_granted"), false);
});

test("user-facing copy is plain and the send path and Refresh agents use the refresh", () => {
  assert.match(NOT_GRANTED_MESSAGE, /don't have access to this agent yet/);
  assert.doesNotMatch(NOT_GRANTED_MESSAGE, /_ISSUER/);
  const plane = readFileSync(new URL("../src/main/controlPlane.ts", import.meta.url), "utf8");
  assert.match(plane, /retryAfterGrantRefresh\(dispatchRaw, forceRefresh/);
  assert.match(plane, /if \(opts\?\.refreshSession\) await forceRefresh\(\)/);
  assert.doesNotMatch(plane, /must match its registered name|[A-Z]+_ISSUER override/);
  for (const f of ["../src/renderer/src/App.tsx", "../src/renderer/src/components/Sidebar.tsx"]) {
    assert.match(readFileSync(new URL(f, import.meta.url), "utf8"), /refreshAgents\(\{ refreshSession: true \}\)/);
  }
});
