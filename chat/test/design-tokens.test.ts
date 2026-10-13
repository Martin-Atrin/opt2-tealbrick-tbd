import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { resolved, resolvedDark } from "../../design/tokens.ts";

/** C139 / C128: TBD's tokens come from the toolkit tokens.ts, stay generated, and every state pair TBD draws is AA. */

const repo = join(import.meta.dirname, "..", "..");
type T = keyof typeof resolved;

test("the generated TBDTokens.swift and tbd-tokens.css match design/tokens.ts", () => {
  execFileSync(process.execPath, ["scripts/design-tokens.ts", "--check"], { cwd: join(repo, "chat"), stdio: "pipe" });
  const swift = readFileSync(join(repo, "native/Sources/TBDDesign/TBDTokens.swift"), "utf8");
  const css = readFileSync(join(repo, "chat/src/renderer/src/tbd-tokens.css"), "utf8");
  const sha = createHash("sha256").update(readFileSync(join(repo, "design/tokens.ts"))).digest("hex");
  assert.match(swift, new RegExp(sha));
  assert.match(css, new RegExp(sha));
  // One brick radius, one face, the web names in Chat.
  assert.match(swift, /public static let radiusBrick: CGFloat = 6\n/);
  assert.match(css, /--tb-radius-brick: 6px;/);
  assert.match(css, /--tb-font: "Nunito"/);
  assert.match(css, /:root\[data-appearance="dark"\] \{\n {2}--tb-paper: #1a1814;/);
});

test("Nunito ships with its OFL licence, the same file for SwiftUI and Chat", () => {
  const files = ["native/Sources/TBDDesign/Fonts/Nunito-VariableFont_wght.ttf", "chat/src/renderer/public/brand/Nunito-VariableFont_wght.ttf"];
  const [a, b] = files.map((f) => createHash("sha256").update(readFileSync(join(repo, f))).digest("hex"));
  assert.equal(a, b);
  for (const f of ["native/Sources/TBDDesign/Fonts/Nunito-OFL.txt", "chat/src/renderer/public/brand/Nunito-OFL.txt"]) {
    const ofl = readFileSync(join(repo, f), "utf8");
    assert.match(ofl, /^Copyright 2014 The Nunito Project Authors/);
    assert.match(ofl, /SIL OPEN FONT LICENSE Version 1\.1/);
  }
});

type RGB = [number, number, number];
const rgb = (v: string): RGB => {
  const m = /^#([0-9a-f]{6})$/i.exec(v.trim());
  if (!m) throw new Error(`not a hex colour: ${v}`);
  return [0, 2, 4].map((i) => Number.parseInt(m[1].slice(i, i + 2), 16)) as RGB;
};
const over = (fg: RGB, a: number, bg: RGB): RGB => fg.map((c, i) => c * a + bg[i] * (1 - a)) as RGB;
const lum = ([r, g, b]: RGB): number => {
  const f = (v: number): number => {
    const c = v / 255;
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b);
};
const ratio = (a: RGB, b: RGB): number => {
  const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p);
  return (x + 0.05) / (y + 0.05);
};

/** [what, fg, bg, need, fg alpha]. Transparent fills are checked over the grounds they sit on (paper, tile). */
const pairs: [string, T, T, number, number?][] = [];
const text = (what: string, fg: T, bg: T, a?: number): void => void pairs.push([what, fg, bg, 4.5, a]);
const ui = (what: string, fg: T, bg: T): void => void pairs.push([what, fg, bg, 3]);
for (const s of ["", "Hover", "Active"]) text(`primary ${s}`, `primary${s}On` as T, `primary${s}Fill` as T);
for (const s of ["Hover", "Active"]) {
  text(`secondary ${s}`, `secondary${s}On` as T, `secondary${s}Fill` as T);
  text(`quiet ${s}`, `quiet${s}On` as T, `quiet${s}Fill` as T);
}
text("danger hover", "dangerHoverOn", "dangerHoverFill");
text("confirm", "dangerConfirmOn", "dangerConfirmFill");
text("confirm hover", "dangerConfirmHoverOn", "dangerConfirmHoverFill");
for (const g of ["paper", "tile"] as T[]) {
  for (const fg of ["secondaryOn", "quietOn", "dangerOn", "tabOn", "ink", "inkSoft", "muted", "tealInk", "brickInk", "link"] as T[]) text(`${fg} on ${g}`, fg, g);
  for (const e of ["fieldEdge", "quietEdge", "secondaryEdge", "dangerEdge", "tabEdge", "lineStrong", "focus", "fieldInvalidEdge"] as T[]) ui(`${e} vs ${g}`, e, g);
}
text("field", "fieldOn", "fieldFill");
text("placeholder", "fieldPlaceholder", "fieldFill");
for (const s of ["Live", "Busy", "NeedsYou", "Idle"]) text(`status ${s}`, `status${s}On` as T, `status${s}Fill` as T);
text("count", "countOn", "countFill");
for (const s of ["Hover", "Current", "CurrentHover"]) text(`chip ${s}`, `tab${s}On` as T, `tab${s}Fill` as T);
text("segmented unselected (muted on plate)", "muted", "plate");
text("segmented selected", "ink", "tile");
text("rail selected (teal-ink on teal-wash)", "tealInk", "tealWash");
text("disabled", "disabledOn", "disabledFill");
ui("switch on thumb vs track", "paper", "tealInk");
ui("switch off thumb vs track", "inkSoft", "plate");
ui("switch off ring vs paper", "lineStrong", "paper");
ui("focus vs teal-wash", "focus", "tealWash");
text("StepFlow upcoming (ink 62%) on tile", "ink", "tile", 0.62);

for (const [theme, map] of [["light", resolved], ["dark", resolvedDark]] as const) {
  test(`every TBD state pair meets WCAG AA in ${theme}`, () => {
    const fails = pairs.flatMap(([what, fg, bg, need, a = 1]) => {
      const ground = rgb(map[bg]);
      const r = ratio(over(rgb(map[fg]), a, ground), ground);
      return r >= need ? [] : [`${what}: ${map[fg]} on ${map[bg]} = ${r.toFixed(2)} (needs ${need})`];
    });
    assert.deepEqual(fails, []);
  });
}
