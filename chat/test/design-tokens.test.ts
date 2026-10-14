import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { resolved, resolvedDark } from "@opt2-tealbrick/ui/tokens";

/** C139 / C150: ONE source — Chat imports @opt2-tealbrick/ui (tokens.css, components.css, fonts); the Swift tokens and
    the app registry are generated from the same package version; every state pair TBD draws is AA. */

const repo = join(import.meta.dirname, "..", "..");
type T = keyof typeof resolved;
const pkg = join(repo, "chat/node_modules/@opt2-tealbrick/ui");

test("Chat imports the kit package and the Swift tokens are generated from the same version", () => {
  execFileSync(process.execPath, ["scripts/design-tokens.ts", "--check"], { cwd: join(repo, "chat"), stdio: "pipe" });
  const version = JSON.parse(readFileSync(join(pkg, "package.json"), "utf8")).version as string;
  const dependency = JSON.parse(readFileSync(join(repo, "chat/package.json"), "utf8")).dependencies["@opt2-tealbrick/ui"] as string;
  assert.match(dependency, new RegExp(`ui-v${version.replace(/\./g, "\\.")}/opt2-tealbrick-ui-${version.replace(/\./g, "\\.")}\\.tgz$`));
  const swift = readFileSync(join(repo, "native/Sources/TBDDesign/TBDTokens.swift"), "utf8");
  const sha = createHash("sha256").update(readFileSync(join(pkg, "dist/tokens.js"))).digest("hex");
  assert.match(swift, new RegExp(`@opt2-tealbrick/ui ${version.replace(/\./g, "\\.")}`));
  assert.match(swift, new RegExp(sha));
  assert.match(swift, /public static let radiusBrick: CGFloat = 6\n/);
  // Chat reads the package's CSS directly; no token copy is left in the renderer.
  const css = readFileSync(join(repo, "chat/src/renderer/src/teal-brick.css"), "utf8");
  assert.match(css, /@import '@opt2-tealbrick\/ui\/tokens\.css';/);
  assert.match(css, /@import '@opt2-tealbrick\/ui\/components\.css';/);
  assert.throws(() => readFileSync(join(repo, "chat/src/renderer/src/tbd-tokens.css")));
  // Dark is the package's data-theme switch, which the native host sets.
  assert.match(readFileSync(join(pkg, "dist/tokens.css"), "utf8"), /\[data-theme="dark"\] \{/);
  assert.match(readFileSync(join(repo, "companion/Dayflow/Dayflow/App/TBDChatView.swift"), "utf8"), /dataset\.theme=/);
});

test("Nunito ships with its OFL licence: the package's woff2 for Chat, the same family as TTF for SwiftUI", () => {
  for (const f of [join(pkg, "dist/fonts/OFL.txt"), join(repo, "native/Sources/TBDDesign/Fonts/Nunito-OFL.txt")]) {
    const ofl = readFileSync(f, "utf8");
    assert.match(ofl, /SIL OPEN FONT LICENSE Version 1\.1/);
    assert.match(ofl, /Nunito Project Authors/);
  }
  assert.match(readFileSync(join(pkg, "dist/tokens.css"), "utf8"), /@font-face \{[^}]*font-family: "Nunito"/);
  assert.match(readFileSync(join(repo, "chat/scripts/build-tbd.ts"), "utf8"), /dist\/fonts\/OFL\.txt/);
  const native = createHash("sha256").update(readFileSync(join(repo, "native/Sources/TBDDesign/Fonts/Nunito-VariableFont_wght.ttf"))).digest("hex");
  const companion = createHash("sha256").update(readFileSync(join(repo, "companion/Dayflow/Dayflow/Fonts/Nunito-VariableFont_wght.ttf"))).digest("hex");
  assert.equal(native, companion);
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
