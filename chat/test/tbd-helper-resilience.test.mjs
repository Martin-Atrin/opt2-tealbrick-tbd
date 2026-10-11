import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomBytes } from "node:crypto";
import { createInterface } from "node:readline";
import { buildHelper } from "../scripts/tbd-helper-build.mjs";

// TBD 0.1.2: a native call nobody awaited (Notification.show -> "notify") was
// rejected by the host when macOS refused notifications. The unhandled rejection
// exited the helper with code 1 and every chat showed "Chat transport stopped (1)".

let dir, helper;
before(async () => {
  dir = mkdtempSync(join(tmpdir(), "tbd-helper-test-"));
  helper = await buildHelper(join(dir, "helper.cjs"));
});
after(() => rmSync(dir, { recursive: true, force: true }));

function startHelper(nodeArgs = []) {
  const data = mkdtempSync(join(dir, "data-"));
  const child = spawn(process.execPath, [...nodeArgs, helper], { env: { ...process.env, TBD_CHAT_DATA: data }, stdio: ["pipe", "pipe", "pipe"] });
  let stderr = "";
  child.stderr.on("data", (d) => { stderr += d; });
  const messages = [];
  const waiters = [];
  createInterface({ input: child.stdout }).on("line", (line) => {
    const message = JSON.parse(line);
    messages.push(message);
    for (const w of [...waiters]) if (w.match(message)) { waiters.splice(waiters.indexOf(w), 1); w.resolve(message); }
  });
  const next = (match) => {
    const found = messages.find(match);
    if (found) { messages.splice(messages.indexOf(found), 1); return Promise.resolve(found); }
    if (child.exitCode !== null) return Promise.reject(new Error(`helper exited ${child.exitCode}`));
    return new Promise((resolve, reject) => waiters.push({ match: (m) => { if (!match(m)) return false; messages.splice(messages.indexOf(m), 1); return true; }, resolve, reject }));
  };
  const write = (message) => child.stdin.write(JSON.stringify(message) + "\n");
  const exited = new Promise((resolve) => child.on("exit", (code) => {
    for (const w of waiters.splice(0)) w.reject(new Error(`helper exited ${code}: ${stderr.split("\n").find((l) => /Error/.test(l)) ?? ""}`));
    resolve(code);
  }));
  return { child, next, write, exited, stderr: () => stderr };
}

test("a rejected fire-and-forget native call does not stop the helper", { timeout: 20_000 }, async () => {
  const h = startHelper();
  h.write({ type: "init", key: randomBytes(32).toString("base64") });
  await h.next((m) => m.type === "ready");

  h.write({ type: "request", id: 1, channel: "studio:notify", args: [{ title: "Agent", body: "reply", agentId: "a" }] });
  const native = await h.next((m) => m.type === "native" && m.method === "notify");
  assert.equal((await h.next((m) => m.type === "reply" && m.id === 1)).error, undefined);
  h.write({ type: "nativeReply", id: native.id, error: "Notifications are not allowed for this application" });

  // Still serving: a later request is answered.
  h.write({ type: "request", id: 2, channel: "studio:session", args: [] });
  const reply = await h.next((m) => m.type === "reply" && m.id === 2);
  assert.equal(reply.error, undefined);
  assert.equal(h.child.exitCode, null);
  assert.match(h.stderr(), /\[helper:error\] native notify failed: Notifications are not allowed/);

  h.write({ type: "shutdown" });
  assert.equal(await h.exited, 0);
});

test("stray rejections and exceptions are logged and the helper keeps serving", { timeout: 20_000 }, async () => {
  // Preloaded into the helper process: fails after the helper has installed its guards.
  const stray = join(dir, "stray.cjs");
  writeFileSync(stray, "setTimeout(() => { Promise.reject(new Error('stray rejection')); setTimeout(() => { throw new Error('stray exception'); }, 10); }, 200);");
  const h = startHelper(["--require", stray]);
  h.write({ type: "init", key: randomBytes(32).toString("base64") });
  await h.next((m) => m.type === "ready");
  await new Promise((r) => setTimeout(r, 400));
  h.write({ type: "request", id: 1, channel: "no:such-channel", args: [] });
  const reply = await h.next((m) => m.type === "reply" && m.id === 1);
  assert.match(reply.error, /Unsupported bridge method/);
  assert.equal(h.child.exitCode, null);
  assert.match(h.stderr(), /\[helper:error\] unhandled rejection: Error: stray rejection/);
  assert.match(h.stderr(), /\[helper:error\] uncaught exception: Error: stray exception/);
  h.write({ type: "shutdown" });
  assert.equal(await h.exited, 0);
});
