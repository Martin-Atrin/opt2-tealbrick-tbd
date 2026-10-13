import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { saveAttachmentIn } from "../src/main/attachmentFile.ts";

test("attachments are saved in the given folder, never overwritten, never outside it", () => {
  const root = mkdtempSync(join(tmpdir(), "tbd-attach-"));
  try {
    const dir = join(root, "Attachments");
    const bytes = new Uint8Array([1, 2, 3]);
    assert.equal(saveAttachmentIn(dir, { name: "plan.docx", bytes }), join(dir, "plan.docx"));
    assert.equal(saveAttachmentIn(dir, { name: "plan.docx", bytes }), join(dir, "plan 2.docx"));
    assert.equal(saveAttachmentIn(dir, { name: "../../evil.zip", bytes }), join(dir, "evil.zip"));
    assert.equal(saveAttachmentIn(dir, { name: ".hidden", bytes }), join(dir, "hidden"));
    assert.equal(saveAttachmentIn(dir, { name: "", bytes }), join(dir, "attachment"));
    assert.deepEqual([...readFileSync(join(dir, "plan 2.docx"))], [1, 2, 3]);
    assert.equal(statSync(join(dir, "plan.docx")).mode & 0o777, 0o600);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
