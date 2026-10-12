import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, symlinkSync, writeFileSync, rmSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { decide, sandboxSettings, type PolicyContext } from "../src/main/filePolicy.ts";

function ctx() {
  const home = realpathSync(mkdtempSync(join(tmpdir(), "tbd-home-")));
  const workspace = join(home, "Library/Application Support/TBD Agent/Workspace");
  const tbdData = join(home, "Library/Application Support/TBD");
  for (const d of [workspace, tbdData, join(home, ".ssh"), join(home, "proj"), join(home, "other")]) mkdirSync(d, { recursive: true });
  writeFileSync(join(home, ".ssh/id_ed25519"), "x");
  const c: PolicyContext = { home, workspace, tbdData, allowed: [join(home, "proj")] };
  return { c, home, done: () => rmSync(home, { recursive: true, force: true }) };
}

test("reads are free only in the agent workspace and granted folders", () => {
  const { c, home, done } = ctx();
  try {
    assert.deepEqual(decide("Read", { file_path: "notes.md" }, c), { kind: "allow" }, "relative = workspace");
    assert.deepEqual(decide("Read", { file_path: join(home, "proj/a.ts") }, c), { kind: "allow" });
    assert.deepEqual(decide("Grep", { path: join(home, "proj"), pattern: "x" }, c), { kind: "allow" });
    assert.deepEqual(decide("Read", { file_path: join(home, "other/a.txt") }, c), { kind: "ask", folder: join(home, "other") });
    assert.deepEqual(decide("Glob", { pattern: "**/*" , path: home }, c), { kind: "ask", folder: null }, "never offer the whole home");
    assert.equal(decide("Write", { file_path: "out.md" }, c).kind, "ask", "writes always ask");
    assert.equal(decide("Bash", { command: "ls" }, c).kind, "ask");
  } finally { done(); }
});

test("secrets are refused everywhere, including through symlinks, ~ and globs", () => {
  const { c, home, done } = ctx();
  try {
    symlinkSync(join(home, ".ssh"), join(home, "proj/keys"));
    for (const [tool, input] of [
      ["Read", { file_path: "~/.ssh/id_ed25519" }],
      ["Read", { file_path: join(home, "proj/keys/id_ed25519") }],
      ["Read", { file_path: join(home, "proj/.env") }],
      ["Read", { file_path: join(home, "proj/server.pem") }],
      ["Read", { file_path: join(home, "Library/Keychains/login.keychain-db") }],
      ["Read", { file_path: join(c.tbdData, "Chat/person.bin") }],
      ["Glob", { pattern: `${home}/.aws/*` }],
      ["Grep", { path: "~/.gnupg", pattern: "x" }],
      ["Edit", { file_path: join(home, ".claude.json") }],
      ["Bash", { command: "cat ~/.ssh/id_ed25519" }],
      ["Bash", { command: `tar cz ${c.tbdData}` }],
    ] as const) {
      assert.equal(decide(tool, input as Record<string, unknown>, c).kind, "deny", `${tool} ${JSON.stringify(input)}`);
    }
  } finally { done(); }
});

test("shell sandbox: writes only to granted folders, secrets and TBD data unreadable, no escape hatch", () => {
  const { c, home, done } = ctx();
  try {
    const s = sandboxSettings(c) as any;
    assert.equal(s.enabled, true); assert.equal(s.allowUnsandboxedCommands, false); assert.equal(s.autoAllowBashIfSandboxed, false);
    assert.deepEqual(s.filesystem.allowWrite, [c.workspace, join(home, "proj")]);
    assert.ok(s.filesystem.denyRead.includes(join(home, ".ssh")) && s.filesystem.denyRead.includes(c.tbdData));
  } finally { done(); }
});
