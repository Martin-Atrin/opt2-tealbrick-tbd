import test from "node:test";
import assert from "node:assert/strict";
import { createAgentAuth, resolveRemoteAgent, credentialOrigin } from "../src/main/agentCredentials.ts";

// PRD §4 / CREDENTIALS R-P1: a person credential never reaches an agent.
const owned = resolveRemoteAgent({ id: "a1", name: "one", url: "https://one.example", accessMode: "private", ownerUserId: "user-1" } as never)!;

test("agent requests never carry an authorization header, for any agent or URL", async () => {
  const auth = createAgentAuth();
  for (const url of ["https://one.example/eve/v1/info", "https://evil.example/x", "http://localhost/x"]) {
    const headers = await auth.agentAuthHeaders(owned, url, { json: true });
    assert.equal(headers.authorization, undefined);
    assert.equal(headers["content-type"], "application/json");
    assert.equal(Object.keys(headers).some((k) => /bundle|token|cookie/i.test(k)), false);
    assert.deepEqual(await auth.decide(owned, url), { mode: "none", reason: "person-credential-never-sent" });
  }
});

test("directory rows with credentials in the URL or non-http schemes do not resolve", () => {
  assert.equal(resolveRemoteAgent({ id: "a", name: "x", url: "https://u:p@one.example" } as never), null);
  assert.equal(resolveRemoteAgent({ id: "a", name: "x", url: "file:///etc/passwd" } as never), null);
  assert.equal(credentialOrigin("http://one.example/x", { allowLoopbackHttp: true }), null);
  assert.equal(credentialOrigin("http://localhost:8080/x", { allowLoopbackHttp: true }), "http://localhost:8080");
});
