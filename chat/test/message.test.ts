import { test } from "node:test";
import assert from "node:assert/strict";
import { buildMessage, fromWire, toWire } from "../src/shared/message.ts";

/**
 * The shape of a user turn as TBD's agent receives it (Anthropic content blocks). Two rules are
 * invisible once written and expensive when broken: an ordinary message stays a plain string, and
 * the text precedes the files it is about. PARITY WP1: files used to arrive as "[object Object]".
 */

const bytes = new Uint8Array([0x68, 0x69]); // "hi"

test("a message with no files stays a plain string", () => {
  assert.equal(buildMessage("what is in flight?"), "what is in flight?");
  assert.equal(buildMessage("what is in flight?", []), "what is in flight?");
});

test("the text comes first, then one block per file in attach order", () => {
  const content = buildMessage("three", [
    { name: "a.pdf", mediaType: "application/pdf", size: 2, bytes },
    { name: "b.png", mediaType: "image/png", size: 2, bytes },
    { name: "c.csv", mediaType: "text/csv", size: 2, bytes },
  ]);
  assert.deepEqual(content, [
    { type: "text", text: "three" },
    { type: "document", title: "a.pdf", source: { type: "base64", media_type: "application/pdf", data: "aGk=" } },
    { type: "image", source: { type: "base64", media_type: "image/png", data: "aGk=" } },
    { type: "document", title: "c.csv", source: { type: "text", media_type: "text/plain", data: "hi" } },
  ]);
});

test("text-like files are read as text, unicode intact", () => {
  const utf8 = new TextEncoder().encode('{"name":"Zoë ✓"}');
  const content = buildMessage("check", [{ name: "x.json", mediaType: "application/json", size: utf8.length, bytes: utf8 }]);
  assert.deepEqual(content, [
    { type: "text", text: "check" },
    { type: "document", title: "x.json", source: { type: "text", media_type: "text/plain", data: '{"name":"Zoë ✓"}' } },
  ]);
});

test("a file sent with no words carries the file and no empty text block", () => {
  assert.deepEqual(buildMessage("", [{ name: "brief.pdf", mediaType: "application/pdf", size: 2, bytes }]), [
    { type: "document", title: "brief.pdf", source: { type: "base64", media_type: "application/pdf", data: "aGk=" } },
  ]);
});

test("a type the model cannot read inline is saved for the agent and named in the text", () => {
  const saved: string[] = [];
  const content = buildMessage("summarise", [{ name: "plan.docx", mediaType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document", size: 2, bytes }], (f) => {
    saved.push(f.name);
    return "/agent/Attachments/plan.docx";
  });
  assert.deepEqual(saved, ["plan.docx"]);
  assert.deepEqual(content, [
    { type: "text", text: 'summarise\n\nAttached file "plan.docx" (application/vnd.openxmlformats-officedocument.wordprocessingml.document) is saved at /agent/Attachments/plan.docx' },
  ]);
});

test("without a place to save, the turn says the file could not be passed on", () => {
  assert.deepEqual(buildMessage("", [{ name: "a.zip", mediaType: "application/zip", size: 2, bytes }]), [
    { type: "text", text: 'Attached file "a.zip" (application/zip) could not be passed on.' },
  ]);
});

test("attachments survive the bridge as base64 and come back byte for byte", () => {
  const wire = toWire({ name: "n.txt", mediaType: "text/plain", size: 2, bytes });
  assert.deepEqual(wire, { name: "n.txt", mediaType: "text/plain", size: 2, data: "aGk=" });
  // What the WebKit bridge delivers is plain JSON.
  const back = fromWire(JSON.parse(JSON.stringify(wire)));
  assert.equal(back.name, "n.txt");
  assert.equal(back.mediaType, "text/plain");
  assert.equal(back.size, 2);
  assert.deepEqual([...back.bytes], [0x68, 0x69]);
});

test("a malformed attachment is refused with a plain error", () => {
  assert.throws(() => fromWire({ name: "x", mediaType: "text/plain", bytes: {} }), { message: "An attached file could not be read. Attach it again." });
  assert.throws(() => fromWire(null), { message: "An attached file could not be read. Attach it again." });
});
