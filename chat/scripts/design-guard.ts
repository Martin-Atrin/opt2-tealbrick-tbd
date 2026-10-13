/* design-guard.ts — fails CI on NEW off-system design values outside TBDDesign (C139).
   Scans native/Sources, companion/Dayflow/Dayflow and chat/src (TBDDesign itself and the generated tbd-tokens.css are
   the token sources and are skipped). Kinds:
     colour  raw colours: Swift Color(red:/white:/hex:/.sRGB…), NSColor(srgbRed:/white:…), system hues (.red, Color.blue…);
             CSS/TS hex, rgb(), hsl()
     font    Swift .font(.system(…)), .custom("…"), text styles (.font(.title2)), NSFont(name:/systemFont…);
             CSS font-family other than var(--tb-font) / var(--tb-font-mono) / inherit; TS fontFamily
     radius  Swift literal cornerRadius; CSS border-radius other than 0 / inherit / var(--tb-radius-*); TS borderRadius
     shape   C125/C126 (CSS): a pill radius on a brick element or a brick radius on a pill element
   Existing debt is allow-listed per file and kind in design/guard-baseline.json, so it can only shrink: a count above
   its baseline (or any hit in a file without one) fails. `--update` lowers counts that went down (never raises one).
   A reviewed exception carries `design-guard: allow` on the same line.
   Usage (from chat/): node scripts/design-guard.ts [--update] [--report] */
import { lstatSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { extname, join, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";

export type Kind = "colour" | "font" | "radius" | "shape";
export type Hit = { kind: Kind; line: number; value: string };

const HUES = "red|green|blue|orange|yellow|purple|pink|gray|grey|mint|teal|cyan|indigo|brown|black|white";
const SWIFT: [Kind, RegExp][] = [
  ["colour", /\bColor\(\s*(?:red|white|hue|hex|\.sRGB|\.displayP3|"#)[^)]*\)/g],
  ["colour", /\bNSColor\(\s*(?:red|srgbRed|calibratedRed|deviceRed|white|calibratedWhite|deviceWhite|hue|calibratedHue)\s*:/g],
  ["colour", new RegExp(`\\b(?:Color|NSColor)\\.(?:${HUES}|system(?:Red|Green|Blue|Orange|Yellow|Purple|Pink|Gray|Mint|Teal|Cyan|Indigo|Brown))\\b`, "g")],
  ["colour", new RegExp(`\\.(?:foregroundStyle|foregroundColor|fill|tint|stroke|background|border|accentColor)\\(\\s*\\.(?:${HUES})\\b`, "g")],
  ["font", /\.font\(\s*\.(?:system|custom)\(/g],
  ["font", /\b(?:Font)?\.custom\(\s*"/g],
  ["font", /\.font\(\s*\.(?:largeTitle|title|title2|title3|headline|subheadline|body|callout|footnote|caption|caption2)\b/g],
  ["font", /\bNSFont\(\s*name\s*:|\bNSFont\.(?:systemFont|boldSystemFont|monospacedSystemFont|monospacedDigitSystemFont)\(/g],
  ["radius", /cornerRadius\s*[:(]\s*[0-9.]+/g],
];
const CSS: [Kind, RegExp, (v: string) => boolean][] = [
  ["colour", /#[0-9a-fA-F]{3,8}\b|rgba?\([^)]*\)|hsla?\([^)]*\)/g, () => false],
  ["font", /font-family\s*:\s*([^;}]+)/g, (v) => /^(var\(--tb-font(-mono)?\)|inherit)$/.test(v.trim())],
  ["radius", /border-radius\s*:\s*([^;}]+)/g, (v) => v.trim().split(/\s+/).every((t) => /^(0|inherit|var\(--tb-radius-[a-z]+\))$/.test(t))],
];
const TS: [Kind, RegExp][] = [
  ["colour", /["'`]\s*(?:#[0-9a-fA-F]{3,8}|rgba?\([^)]*\)|hsla?\([^)]*\))\s*["'`]/g],
  ["font", /\bfontFamily\s*:(?!\s*["'`]var\(--)/g],
  ["radius", /\bborderRadius\s*:\s*["'`]?[0-9]/g],
];
const allowed = (line: string): boolean => /(?:design-guard|check-system):\s*allow/.test(line);
const blankComments = (text: string): string => text.replace(/\/\*[\s\S]*?\*\//g, (c) => c.replace(/[^\n]/g, " "));

export function scanSwift(text: string): Hit[] {
  const hits: Hit[] = [];
  blankComments(text).split("\n").forEach((raw, i) => {
    const line = raw.replace(/(^|[^:"])\/\/.*$/, "$1"); // drop // comments (keeps "https://" in strings)
    if (allowed(raw)) return;
    for (const [kind, re] of SWIFT) for (const m of line.matchAll(re)) hits.push({ kind, line: i + 1, value: m[0].slice(0, 60) });
  });
  return hits;
}

export function scanTs(text: string): Hit[] {
  const hits: Hit[] = [];
  blankComments(text).split("\n").forEach((raw, i) => {
    const line = raw.replace(/(^|[^:"'`])\/\/.*$/, "$1");
    if (allowed(raw)) return;
    for (const [kind, re] of TS) for (const m of line.matchAll(re)) hits.push({ kind, line: i + 1, value: m[0].slice(0, 60) });
  });
  return hits;
}

const PILL_SEL = /(?:^|[.\-_#\s>["=])(tags?|chips?|badge|count|pill|paypill|status-pill|switch|segmented|radio)(?![a-z])/i;
const BRICK_SEL = /(btn|button|input|select|textarea|card|panel|dialog|inspector|toast|menu|tabs?|nav|node|notice|copy|field|avatar|table|choice|close|bubble|modal)(?![a-z])/i;
const IS_PILL = /999px|var\(--tb-radius-pill\)|50%/;
const IS_BRICK = /var\(--tb-radius-brick\)|var\(--tb-radius\)|\b[1-9]\d?px\b/;

export function scanCss(text: string): Hit[] {
  const hits: Hit[] = [];
  const clean = blankComments(text);
  clean.split("\n").forEach((line, i) => {
    if (allowed(text.split("\n")[i] ?? "")) return;
    for (const [kind, re, ok] of CSS) for (const m of line.matchAll(re)) if (!ok((m[1] ?? m[0]).trim())) hits.push({ kind, line: i + 1, value: m[0].slice(0, 60) });
  });
  // shape pass, selector-aware (innermost rule blocks), as the toolkit's check-system.ts
  for (const m of clean.matchAll(/([^{}@;]+)\{([^{}]*)\}/g)) {
    const sel = m[1].trim();
    const r = /border-radius\s*:\s*([^;]+)/.exec(m[2])?.[1];
    if (!r || /(?:design-guard|check-system):\s*allow/.test(m[2])) continue;
    const line = clean.slice(0, (m.index ?? 0) + (m[1].length - m[1].trimStart().length)).split("\n").length;
    const parts = sel.split(",").map((x) => x.trim());
    const last = (x: string): string => x.split(/[\s>+~]+/).pop() ?? "";
    const pillEl = parts.every((x) => PILL_SEL.test(last(x)));
    const brickEl = parts.some((x) => BRICK_SEL.test(last(x)) && !PILL_SEL.test(last(x)) && !/::(before|after)/.test(x));
    if (brickEl && IS_PILL.test(r)) hits.push({ kind: "shape", line, value: `pill radius on brick element ${sel.slice(0, 50)}` });
    else if (pillEl && IS_BRICK.test(r) && !IS_PILL.test(r)) hits.push({ kind: "shape", line, value: `brick radius on pill element ${sel.slice(0, 50)}` });
  }
  return hits;
}

const repo = join(import.meta.dirname, "..", "..");
const ROOTS = ["native/Sources", "companion/Dayflow/Dayflow", "chat/src"];
const SKIP_DIRS = new Set(["node_modules", "out", "build", "build.noindex", "DerivedData", ".build", "public", "Assets.xcassets", "Fonts"]);
const SKIP_FILES = new Set(["native/Sources/TBDDesign", "chat/src/renderer/src/tbd-tokens.css"]); // the token sources
const BASELINE = join(repo, "design", "guard-baseline.json");

export function scanRepo(root = repo): Map<string, Hit[]> {
  const out = new Map<string, Hit[]>();
  const walk = (dir: string): void => {
    for (const name of readdirSync(dir)) {
      const p = join(dir, name);
      const rel = relative(root, p).split(sep).join("/");
      if (SKIP_DIRS.has(name) || name.startsWith(".") || SKIP_FILES.has(rel)) continue;
      const st = lstatSync(p);
      if (st.isSymbolicLink()) continue;
      if (st.isDirectory()) { walk(p); continue; }
      const ext = extname(name);
      if (name.endsWith(".d.ts") || /\.test\.tsx?$/.test(name)) continue;
      const text = ext === ".swift" || ext === ".css" || ext === ".ts" || ext === ".tsx" ? readFileSync(p, "utf8") : null;
      if (text === null) continue;
      const hits = ext === ".swift" ? scanSwift(text) : ext === ".css" ? scanCss(text) : scanTs(text);
      if (hits.length) out.set(rel, hits);
    }
  };
  for (const r of ROOTS) walk(join(root, r));
  return out;
}

type Counts = Partial<Record<Kind, number>>;
const count = (hits: Hit[]): Counts => hits.reduce<Counts>((c, h) => ({ ...c, [h.kind]: (c[h.kind] ?? 0) + 1 }), {});

/** Files and kinds whose count is above the baseline (a file missing from the baseline has a baseline of 0). */
export function compare(found: Map<string, Hit[]>, baseline: Record<string, Counts>): { file: string; kind: Kind; now: number; allowed: number; hits: Hit[] }[] {
  const over: { file: string; kind: Kind; now: number; allowed: number; hits: Hit[] }[] = [];
  for (const [file, hits] of found) {
    const c = count(hits);
    for (const kind of Object.keys(c) as Kind[]) {
      const allowedN = baseline[file]?.[kind] ?? 0;
      if ((c[kind] ?? 0) > allowedN) over.push({ file, kind, now: c[kind] ?? 0, allowed: allowedN, hits: hits.filter((h) => h.kind === kind) });
    }
  }
  return over;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const args = process.argv.slice(2);
  const found = scanRepo();
  const baseline = JSON.parse(readFileSync(BASELINE, "utf8")) as { files: Record<string, Counts> };
  const totals = (m: Record<string, Counts>): Counts => Object.values(m).reduce<Counts>((t, c) => {
    for (const k of Object.keys(c) as Kind[]) t[k] = (t[k] ?? 0) + (c[k] ?? 0);
    return t;
  }, {});
  if (args.includes("--update")) {
    // Lower only: a count may go down or a file may leave the list; nothing is ever raised or added here.
    const next: Record<string, Counts> = {};
    for (const [file, allowedCounts] of Object.entries(baseline.files)) {
      const c = count(found.get(file) ?? []);
      const kept: Counts = {};
      for (const k of Object.keys(allowedCounts) as Kind[]) if ((c[k] ?? 0) > 0) kept[k] = Math.min(c[k] ?? 0, allowedCounts[k] ?? 0);
      if (Object.keys(kept).length) next[file] = kept;
    }
    writeFileSync(BASELINE, `${JSON.stringify({ ...baseline, totals: totals(next), files: next }, null, 2)}\n`);
    console.log(`design-guard: baseline lowered to ${JSON.stringify(totals(next))}`);
  }
  const current = JSON.parse(readFileSync(BASELINE, "utf8")) as { files: Record<string, Counts> };
  const over = compare(found, current.files);
  const now: Record<string, Counts> = Object.fromEntries([...found].map(([f, h]) => [f, count(h)]));
  if (args.includes("--report")) for (const [f, c] of Object.entries(now).sort()) console.log(`${f}\t${JSON.stringify(c)}`);
  for (const o of over) {
    console.error(`${o.file}: ${o.now} off-system ${o.kind} value(s), baseline allows ${o.allowed}`);
    for (const h of o.hits.slice(0, 8)) console.error(`  ${o.file}:${h.line}  ${h.value}`);
  }
  if (over.length) {
    console.error("\ndesign-guard: use TBDDesign tokens/components (Swift) or var(--tb-*) (Chat). Reviewed exception: `design-guard: allow` on the line.");
    process.exit(1);
  }
  const t = totals(now);
  console.log(`design-guard: clean against the baseline. Remaining debt ${JSON.stringify(t)} (allowed ${JSON.stringify(totals(current.files))})`);
}
