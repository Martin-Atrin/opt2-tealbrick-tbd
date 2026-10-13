import test from "node:test";
import assert from "node:assert/strict";
import { compare, scanCss, scanSwift, scanTs } from "../scripts/design-guard.ts";

/** L34: the guard stays quiet on the good case AND fires on the bad case, for every kind. */

test("Swift: raw colours, literal fonts and radii fire; tokens stay quiet", () => {
  const bad = [
    'let a = Color(red: 0.1, green: 0.2, blue: 0.3)',
    'x.foregroundStyle(.red)',
    'let c = Color.orange',
    'let n = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)',
    'Text("a").font(.system(size: 12))',
    'Text("a").font(.custom("Switzer", size: 13))',
    'Text("a").font(.title2)',
    'RoundedRectangle(cornerRadius: 4)',
    'x.cornerRadius(8)',
  ];
  for (const line of bad) assert.equal(scanSwift(line).length, 1, line);
  const good = [
    'x.foregroundStyle(TBDColor.ink).font(TBDTokens.Typography.body)',
    'RoundedRectangle(cornerRadius: TBDTokens.Radius.base)',
    'TBDBrickShape().fill(TBDColor.tile)',
    '// Color(red: 1, green: 0, blue: 0) in a comment',
    'let a = Color(red: 1, green: 0, blue: 0) // design-guard: allow',
  ];
  for (const line of good) assert.deepEqual(scanSwift(line), [], line);
});

test("CSS: raw values fire, tokens stay quiet; shape fires both ways", () => {
  assert.deepEqual(scanCss(".a { color: #fff; font-family: Georgia; border-radius: 4px; }").map((h) => h.kind).sort(), ["colour", "font", "radius"]);
  assert.deepEqual(scanCss(".a { color: var(--tb-ink); font-family: var(--tb-font); border-radius: var(--tb-radius-brick); }"), []);
  assert.deepEqual(scanCss("/* #fff */ .a { color: var(--tb-ink); }"), []);
  assert.deepEqual(scanCss(".icon-btn { border-radius: var(--tb-radius-pill); }").map((h) => h.kind), ["shape"]);
  assert.deepEqual(scanCss(".agent-chip { border-radius: var(--tb-radius-brick); }").map((h) => h.kind), ["shape"]);
  assert.deepEqual(scanCss(".agent-chip { border-radius: var(--tb-radius-pill); } .btn { border-radius: var(--tb-radius-brick); }"), []);
});

test("TS: inline raw colours and fonts fire; token references stay quiet", () => {
  assert.equal(scanTs('const p = ["#2ec4a6"];').length, 1);
  assert.equal(scanTs('<span style={{ fontFamily: "Georgia" }} />').length, 1);
  assert.deepEqual(scanTs('<span style={{ fontFamily: "var(--tb-font-mono)" }} />'), []);
  assert.deepEqual(scanTs('const level = (heading[1] ?? "#").length;'), []);
});

test("the baseline only lets debt shrink", () => {
  const hits = new Map([["a.swift", [{ kind: "colour" as const, line: 1, value: "x" }, { kind: "colour" as const, line: 2, value: "y" }]]]);
  assert.deepEqual(compare(hits, { "a.swift": { colour: 2 } }), []);
  assert.equal(compare(hits, { "a.swift": { colour: 1 } }).length, 1);
  assert.equal(compare(hits, {}).length, 1);
  assert.equal(compare(new Map([["new.swift", [{ kind: "font" as const, line: 1, value: "z" }]]]), { "a.swift": { colour: 2 } })[0]?.file, "new.swift");
});
