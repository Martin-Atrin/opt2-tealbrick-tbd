import test from "node:test";
import assert from "node:assert/strict";
import { generateKeyPair, signReleaseIndex } from "@opt2-tealbrick/manifest";
import { checkForUpdate, compareVersions, selectDesktopRelease, INDEX_URL } from "../src/main/updates.ts";

const rel = (o: Record<string, unknown>) => ({ product: "tbd", kind: "desktop", channel: "stable", version: "0.2.0", artifact: { url: "https://github.com/x/TBD.zip", sha256: "sha256:ab" }, minOs: "14.0", ...o });

test("version compare and desktop selection", () => {
  assert.equal(compareVersions("1.2.3", "1.2.3"), 0);
  assert.equal(compareVersions("1.10.0", "1.9.9"), 1);
  assert.equal(compareVersions("1.0.0-dev.1", "1.0.0"), -1);
  const body = { schema: "opt2.release-index/v2" as const, releases: [
    rel({ version: "0.3.0" }), rel({ version: "0.4.0", channel: "dev" }), rel({ version: "0.5.0", kind: "app" }),
    rel({ version: "0.6.0", minOs: "15.0" }), rel({ version: "0.7.0", product: "other" }), rel({ version: "0.8.0", artifact: { url: "http://insecure", sha256: "x" } }),
  ] };
  const r = selectDesktopRelease(body, { version: "0.1.0", os: "14.5" });
  assert.equal(r?.version, "0.3.0"); assert.equal(r?.sha256, "ab");
  assert.equal(selectDesktopRelease(body, { version: "0.1.0", os: "14.5", channel: "dev" })?.version, "0.4.0");
  assert.equal(selectDesktopRelease(body, { version: "0.3.0", os: "14.5" }), null);
});

test("feed is accepted only with a valid envelope over this exact body", async () => {
  const key = await generateKeyPair();
  const body = { schema: "opt2.release-index/v2" as const, generatedAt: "2026-10-11T00:00:00Z", releases: [rel({ version: "0.9.0" })], offers: [] };
  const now = Date.now();
  const jws = await signReleaseIndex(body, { iat: Math.floor(now / 1000) }, key as never);
  const jwks = { keys: [(key as any).publicJwk] };
  const serve = (b: unknown, env: string) => (async (url: string) => ({ ok: true, status: 200, url, text: async () => (url === INDEX_URL ? JSON.stringify(b) : env) })) as unknown as typeof fetch;
  assert.equal((await checkForUpdate({ version: "0.1.0", os: "14.0" }, { fetch: serve(body, jws), jwks, now: () => now }))?.version, "0.9.0");
  const tampered = { ...body, releases: [rel({ version: "9.9.9", artifact: { url: "https://evil.example/x.zip", sha256: "00" } })] };
  await assert.rejects(checkForUpdate({ version: "0.1.0", os: "14.0" }, { fetch: serve(tampered, jws), jwks, now: () => now }), /did not verify/);
  const other = await generateKeyPair();
  await assert.rejects(checkForUpdate({ version: "0.1.0", os: "14.0" }, { fetch: serve(body, jws), jwks: { keys: [(other as any).publicJwk] }, now: () => now }), /did not verify/);
});
