/* design-sameness.ts: the TBD "sameness proof". The same ten components rendered three ways, light and dark,
   measured and compared:
     WEB         the released kit @opt2-tealbrick/ui (tokens.css + components.css + fonts), kit markup (from mockups/components.html)
     TBD NATIVE  SwiftUI TBDDesign, rendered by `tbd-design-shots --sameness` (native/Sources/TBDDesignShots/Sameness.swift)
     TBD CHAT    the Chat renderer's own CSS (styles.css + teal-brick.css, which imports the same package) with the markup its components render
   Run (from chat/, Node 24+):
     node scripts/design-sameness.ts [--native <path to tbd-design-shots>] [--out <dir>] [--page <html>] [--kit <design dir>] [--strict]
   - WEB and CHAT: two tiny static pages on a local server, headless Chromium (playwright-core, PW_CORE or the default
     checkout), DPR 2. Every [data-m] element is measured with getComputedStyle + getBoundingClientRect.
   - NATIVE: pass --native to run the binary, or run `tbd-design-shots --sameness <out>` first (it writes
     <out>/native-metrics.json and the native PNGs). Build: swift build --package-path native --product tbd-design-shots
   - Output: <out>/<cell>-<web|native|chat>-<light|dark>.png, <out>/sameness.json and the page (default <kit>/../leads/tbd-design/TBD-SAMENESS.html: evidence lives outside the design folder, whose
     check-system guard would flag the raw values the page prints on purpose).
   Product CSS and Swift are never changed to make a row pass: a mismatch is a finding. Exit 1 on a FAIL only with --strict. */
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { homedir } from "node:os";
import { dirname, extname, join, normalize, relative, resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";
import { CELLS, type CellDef, type Col, PROBES, type Prop, type Theme, WEB_CANVAS_CSS } from "./design-sameness/cells.ts";
import { type Cell, type Metrics, type Row, add, compareProbe, emptyCounts } from "./design-sameness/compare.ts";
import { type ComponentResult, type Finding, page } from "./design-sameness/report.ts";

const PW = process.env.PW_CORE ?? "/Users/puma/work/active/website-martin-redesign/node_modules/playwright-core/index.mjs";
const args = process.argv.slice(2);
const flag = (name: string): string | undefined => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined; };
const kit = resolve(flag("--kit") ?? process.env.TB_KIT ?? "/Users/puma/work/active/tealbrick-opt2/coordination/design");
const outDir = resolve(flag("--out") ?? join(kit, "screens", "tbd-sameness"));
const pagePath = resolve(flag("--page") ?? join(kit, "..", "leads", "tbd-design", "TBD-SAMENESS.html"));
const nativeBin = flag("--native");
const strict = args.includes("--strict");
const repo = join(import.meta.dirname, "..", "..");
const rendererSrc = join(repo, "chat", "src", "renderer", "src");
const publicBrand = join(repo, "chat", "src", "renderer", "public", "brand");
/** The released kit (@opt2-tealbrick/ui): the web reference AND what Chat imports (one source). */
const pkgDist = join(repo, "chat", "node_modules", "@opt2-tealbrick", "ui", "dist");
mkdirSync(outDir, { recursive: true });

// ───────────────────────────── the two pages

const cellBox = (c: CellDef, markup: string): string => `<div class="sx-cell" id="cell-${c.id}" style="width:${c.w}px;height:${c.h}px">${markup}</div>`;
const SHELL_CSS = `.sx-cell { box-sizing: border-box; padding: 16px; background: var(--tb-paper); position: relative; overflow: hidden; margin: 0 0 24px; }
.sx-refs { position: absolute; left: -9999px; top: 0; display: flex; gap: 12px; }
*, *::before, *::after { animation: none !important; transition: none !important; }`;

function webPage(): string {
  const refs = CELLS.map((c) => c.refs ?? "").join("");
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>sameness web</title>
<link rel="stylesheet" href="/pkg/tokens.css"><link rel="stylesheet" href="/pkg/components.css">
<style>${WEB_CANVAS_CSS}\n${SHELL_CSS}</style></head>
<body class="tb-root">${CELLS.map((c) => cellBox(c, c.web)).join("\n")}<div class="sx-refs">${refs}</div></body></html>`;
}
function chatPage(): string {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>sameness chat</title>
<link rel="stylesheet" href="/chat-css/styles.css"><link rel="stylesheet" href="/chat-css/teal-brick.css">
<style>${SHELL_CSS}</style></head>
<body>${CELLS.map((c) => cellBox(c, c.chat)).join("\n")}</body></html>`;
}

// ───────────────────────────── server

const TYPES: Record<string, string> = { ".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8", ".ttf": "font/ttf", ".woff2": "font/woff2", ".webp": "image/webp", ".png": "image/png", ".svg": "image/svg+xml" };
function route(url: string): { body: string | Buffer; type: string } | null {
  const path = decodeURIComponent(url.split("?")[0]);
  if (path === "/web.html") return { body: webPage(), type: TYPES[".html"] };
  if (path === "/chat.html") return { body: chatPage(), type: TYPES[".html"] };
  // teal-brick.css imports '@opt2-tealbrick/ui/tokens.css' (Vite resolves it in the app; here the bare path maps to the package).
  const maps: [string, string][] = [["/pkg/", pkgDist], ["/chat-css/@opt2-tealbrick/ui/", pkgDist], ["/kit/", kit], ["/chat-css/brand/", publicBrand], ["/chat-css/", rendererSrc], ["/brand/", publicBrand]];
  for (const [prefix, root] of maps) {
    if (!path.startsWith(prefix)) continue;
    const file = normalize(join(root, path.slice(prefix.length)));
    if (!file.startsWith(root) || !existsSync(file)) return null;
    return { body: readFileSync(file), type: TYPES[extname(file)] ?? "application/octet-stream" };
  }
  return null;
}

// ───────────────────────────── measuring (runs in the page)

type Raw = Record<string, Partial<Record<Prop, string | number>>>;
const measureInPage = (): Raw => {
  const out: Raw = {};
  const cv = document.createElement("canvas");
  cv.width = cv.height = 1;
  const cx = cv.getContext("2d", { willReadFrequently: true }) as CanvasRenderingContext2D;
  const hex2 = (v: number): string => Math.round(v).toString(16).padStart(2, "0");
  const holder = document.createElement("span");
  document.body.append(holder);
  /** Any CSS colour (rgb, color-mix, keyword) as "#rrggbb", "#rrggbb@alpha" or "transparent", resolved by the browser. */
  const colour = (input: string): string => {
    const s = input.trim();
    if (!s || s === "transparent") return "transparent";
    holder.style.color = "";
    holder.style.color = s;
    const resolved = getComputedStyle(holder).color;
    let r = 0, g = 0, b = 0, a = 1;
    const rgbM = /^rgba?\(([^)]+)\)$/.exec(resolved);
    const srgbM = /^color\(srgb ([^)]+)\)$/.exec(resolved);
    if (rgbM) {
      const p = rgbM[1].split(/[\s,/]+/).filter(Boolean).map(Number);
      [r, g, b] = p; a = p.length > 3 ? p[3] : 1;
    } else if (srgbM) {
      const p = srgbM[1].split(/[\s/]+/).filter(Boolean).map(Number);
      r = p[0] * 255; g = p[1] * 255; b = p[2] * 255; a = p.length > 3 ? p[3] : 1;
    } else {
      cx.clearRect(0, 0, 1, 1); cx.fillStyle = "#000"; cx.fillStyle = resolved; cx.fillRect(0, 0, 1, 1);
      const d = cx.getImageData(0, 0, 1, 1).data;
      r = d[0]; g = d[1]; b = d[2]; a = d[3] / 255;
    }
    if (a < 0.005) return "transparent";
    const base = `#${hex2(r)}${hex2(g)}${hex2(b)}`;
    return a >= 0.995 ? base : `${base}@${a.toFixed(2)}`;
  };
  /** Splits at top-level separators only (not inside parentheses). */
  const splitTop = (s: string, sep: RegExp): string[] => {
    const parts: string[] = [];
    let depth = 0, cur = "";
    for (const ch of s) {
      if (ch === "(") depth++;
      if (ch === ")") depth--;
      if (depth === 0 && sep.test(ch)) { if (cur.trim()) parts.push(cur.trim()); cur = ""; } else cur += ch;
    }
    if (cur.trim()) parts.push(cur.trim());
    return parts;
  };
  /** The first inset, unblurred shadow is the edge: a ring (spread) or a one-sided rule (offset). */
  const edgeOf = (shadow: string): [string, number] => {
    if (shadow === "none") return ["none", 0];
    for (const sh of splitTop(shadow, /,/)) {
      const tokens = splitTop(sh, /\s/);
      if (!tokens.includes("inset")) continue;
      const col = tokens.find((t) => t.includes("(")) ?? tokens.find((t) => /^[a-z#]/i.test(t) && t !== "inset");
      if (!col) continue;
      const n = tokens.filter((t) => /^-?[\d.]+(px)?$/.test(t)).map(Number.parseFloat);
      const [x = 0, y = 0, blur = 0, spread = 0] = n;
      if (blur === 0) return [colour(col), spread || Math.max(Math.abs(x), Math.abs(y))];
    }
    return ["none", 0];
  };
  const round = (n: number): number => Math.round(n * 100) / 100;
  for (const el of document.querySelectorAll<HTMLElement>("[data-m]")) {
    const cs = getComputedStyle(el);
    const rect = el.getBoundingClientRect();
    const [edgeColor, edgeWidth] = edgeOf(cs.boxShadow);
    const r = Number.parseFloat(cs.borderTopLeftRadius);
    const rec: Raw[string] = {
      fontFamily: cs.fontFamily.split(",")[0].replace(/["']/g, "").trim(),
      fontSize: round(Number.parseFloat(cs.fontSize)), fontWeight: Number(cs.fontWeight),
      lineHeight: cs.lineHeight === "normal" ? "normal" : round(Number.parseFloat(cs.lineHeight)),
      padL: round(Number.parseFloat(cs.paddingLeft)), padR: round(Number.parseFloat(cs.paddingRight)),
      padT: round(Number.parseFloat(cs.paddingTop)), padB: round(Number.parseFloat(cs.paddingBottom)),
      height: round(rect.height), width: round(rect.width),
      radius: r >= Math.min(rect.width, rect.height) / 2 && r > 0 ? "pill" : round(r),
      bg: colour(cs.backgroundColor), color: colour(cs.color), edgeColor, edgeWidth,
    };
    for (const id of (el.dataset.m ?? "").split(" ").filter(Boolean)) out[id] = rec;
  }
  holder.remove();
  return out;
};

// ───────────────────────────── browser

interface PwPage { goto(u: string): Promise<unknown>; evaluate<T>(f: unknown): Promise<T>; locator(s: string): { screenshot(o: { path: string }): Promise<unknown> } }
interface PwBrowser { newContext(o: unknown): Promise<{ newPage(): Promise<PwPage> }>; close(): Promise<void> }
interface PwChromium { launch(o?: unknown): Promise<PwBrowser> }

async function launch(chromium: PwChromium): Promise<PwBrowser> {
  if (process.env.CHROME_PATH) return chromium.launch({ executablePath: process.env.CHROME_PATH });
  const attempts: unknown[] = [{}];
  const cache = join(homedir(), "Library", "Caches", "ms-playwright");
  if (existsSync(cache)) {
    for (const d of readdirSync(cache).filter((x) => x.startsWith("chromium-")).sort().reverse()) {
      attempts.push({ executablePath: join(cache, d, "chrome-mac-arm64", "Google Chrome for Testing.app", "Contents", "MacOS", "Google Chrome for Testing") });
    }
  }
  attempts.push({ channel: "chrome" });
  let last: unknown;
  for (const a of attempts) {
    try { return await chromium.launch(a); } catch (e) { last = e; }
  }
  throw last;
}

async function shootColumn(browser: PwBrowser, base: string, col: "web" | "chat"): Promise<{ metrics: Record<Theme, Raw>; fontOk: boolean }> {
  const ctx = await browser.newContext({ viewport: { width: 1000, height: 2400 }, deviceScaleFactor: 2, reducedMotion: "reduce" });
  const pg = await ctx.newPage();
  await pg.goto(`${base}/${col}.html`);
  const metrics = {} as Record<Theme, Raw>;
  let fontOk = true;
  for (const theme of ["light", "dark"] as Theme[]) {
    await pg.evaluate(`(async () => {
      const root = document.documentElement;
      root.removeAttribute("data-theme"); root.removeAttribute("data-appearance");
      ${theme === "dark" ? `root.setAttribute("data-theme", "dark");` : ""}
      await document.fonts.load("400 14px Nunito"); await document.fonts.load("900 14px Nunito"); await document.fonts.ready;
    })()`);
    fontOk = fontOk && (await pg.evaluate<boolean>(`document.fonts.check("800 14px Nunito")`));
    metrics[theme] = await pg.evaluate<Raw>(measureInPage);
    for (const c of CELLS) await pg.locator(`#cell-${c.id}`).screenshot({ path: join(outDir, `${c.id}-${col}-${theme}.png`) });
  }
  return { metrics, fontOk };
}

// ───────────────────────────── main

function pngSize(file: string): { w: number; h: number } {
  const b = readFileSync(file);
  return { w: b.readUInt32BE(16), h: b.readUInt32BE(20) };
}

const wrap = (raw: Raw, src: "measured"): Record<string, Partial<Record<Prop, Cell>>> => {
  const out: Record<string, Partial<Record<Prop, Cell>>> = {};
  for (const [id, props] of Object.entries(raw)) {
    out[id] = {};
    for (const [k, v] of Object.entries(props)) out[id][k as Prop] = { v, src };
  }
  return out;
};

async function main(): Promise<void> {
  if (nativeBin) execFileSync(nativeBin, ["--sameness", outDir], { stdio: "inherit" });
  const nativeFile = join(outDir, "native-metrics.json");
  if (!existsSync(nativeFile)) throw new Error(`${nativeFile} missing: run "tbd-design-shots --sameness ${outDir}" or pass --native <binary>`);

  const server = createServer((req, res) => {
    const hit = route(req.url ?? "/");
    if (!hit) { res.writeHead(404).end("not found"); return; }
    res.writeHead(200, { "content-type": hit.type, "cache-control": "no-store" }).end(hit.body);
  });
  await new Promise<void>((ok) => server.listen(0, "127.0.0.1", ok));
  const port = (server.address() as { port: number }).port;
  const base = `http://127.0.0.1:${port}`;

  const metrics: Metrics = { web: { light: {}, dark: {} }, chat: { light: {}, dark: {} }, native: { light: {}, dark: {} } };
  let browser: PwBrowser | undefined;
  const fonts: Record<string, boolean> = {};
  try {
    const { chromium } = (await import(pathToFileURL(PW).href)) as { chromium: PwChromium };
    browser = await launch(chromium);
    for (const col of ["web", "chat"] as const) {
      const r = await shootColumn(browser, base, col);
      fonts[col] = r.fontOk;
      for (const t of ["light", "dark"] as Theme[]) metrics[col][t] = wrap(r.metrics[t], "measured");
    }
  } finally {
    await browser?.close();
    server.close();
  }
  if (!fonts.web || !fonts.chat) throw new Error(`Nunito did not load (web ${fonts.web}, chat ${fonts.chat})`);

  const native = JSON.parse(readFileSync(nativeFile, "utf8")) as { cells: Record<string, { w: number; h: number }>; probes: Record<Theme, Record<string, Partial<Record<Prop, { v: string | number; src: "measured" | "declared" }>>>> };
  for (const t of ["light", "dark"] as Theme[]) metrics.native[t] = native.probes[t];

  // every PNG is the cell size at 2x
  const problems: string[] = [];
  for (const c of CELLS) for (const col of ["web", "native", "chat"] as Col[]) for (const t of ["light", "dark"] as Theme[]) {
    const file = join(outDir, `${c.id}-${col}-${t}.png`);
    if (!existsSync(file)) { problems.push(`missing ${file}`); continue; }
    const s = pngSize(file);
    if (s.w !== c.w * 2 || s.h !== c.h * 2) problems.push(`${c.id}-${col}-${t}.png is ${s.w}x${s.h}, expected ${c.w * 2}x${c.h * 2}`);
  }
  if (problems.length) throw new Error(`cell size mismatch:\n  ${problems.join("\n  ")}`);

  // reference probes (web kit .sm controls), used by the "36 is the kit's .sm" note
  const refs: Record<string, Cell> = {};
  for (const [id, props] of Object.entries(metrics.web.light)) if (id.endsWith("-sm") && props.height) refs[id] = props.height;

  const total = emptyCounts();
  const results: ComponentResult[] = CELLS.map((cell) => {
    const probes = PROBES.filter((p) => p.cell === cell.id).map((spec) => ({ spec, rows: compareProbe(spec, metrics, refs) }));
    const counts = emptyCounts();
    for (const p of probes) add(counts, p.rows);
    add(total, probes.flatMap((p) => p.rows));
    return { cell, probes, counts };
  });

  const show = (r: Row, col: Col): string => {
    const c = r.cols[col];
    if (c.na) return "n/a";
    return c.light === c.dark || c.dark === undefined ? String(c.light) : `${c.light} / ${c.dark}`;
  };
  const findings: Finding[] = [];
  for (const res of results) for (const p of res.probes) for (const r of p.rows) {
    if (r.status === "fail" || (r.status === "documented" && r.catch)) {
      findings.push({ probe: p.spec.id, prop: r.prop, kind: r.status === "fail" ? "FAIL" : "DOCUMENTED, with a catch", web: show(r, "web"), native: show(r, "native"), chat: show(r, "chat"), note: [r.note, r.catch].filter(Boolean).join(". ") });
    }
  }

  const generated = new Date().toISOString().slice(0, 10);
  writeFileSync(join(outDir, "sameness.json"), `${JSON.stringify({
    generated, tolerance: { sizePx: 0.5, colour: "exact hex (alpha within 0.01)", weight: "equal", family: "Nunito" },
    summary: { total, components: Object.fromEntries(results.map((r) => [r.cell.id, r.counts])) },
    findings,
    components: results.map((r) => ({ id: r.cell.id, title: r.cell.title, what: r.cell.what, size: { w: r.cell.w, h: r.cell.h }, probes: r.probes.map((p) => ({ id: p.spec.id, label: p.spec.label, missing: p.spec.missing ?? null, rows: p.rows })) })),
    metrics,
  }, null, 2)}\n`);

  const notes = [
    "WEB: the released kit <code>@opt2-tealbrick/ui</code> (<code>tokens.css</code> with its self-hosted Nunito, <code>components.css</code>), kit markup copied from <code>mockups/components.html</code>. The canvas cards use the rules of <code>mockups/build-workspace.ts</code>.",
    "TBD CHAT: <code>styles.css</code> + <code>teal-brick.css</code> (which imports the same package: one source), with the markup the Chat components render (<code>StepFlow.tsx</code>, <code>AgentCard.tsx</code>, <code>FirstRun.tsx</code>, <code>SignIn.tsx</code>, <code>Palette.tsx</code>). The StepFlow cell has no portal and no scrim.",
    "TBD NATIVE: the real TBDDesign views in an offscreen window at 2x, from <code>tbd-design-shots --sameness</code>. Frames come from the rendered SwiftUI layout or from the rendered pixels of the cell. A value marked <sup>d</sup> is declared: the token constant the component is built from, resolved under the appearance through NSColor. A value without a mark is measured.",
    "Web and Chat values are measured with getComputedStyle and getBoundingClientRect. Line height is measured for both and kept in <code>sameness.json</code>; SwiftUI sets no line height, so it is not compared.",
    "Tabs: the kit .tb-tabs is compared with TBDNavItem, the native brick nav item. TBDSegmented is the pill, the kit .tb-segmented, and is not part of this proof.",
    "App chip: the web kit has no app chip. Its reference is the app header band of a canvas app card, plus the kit AppIcon 16. Size, padding and type are N/A for the band.",
    "Documented deviations (TBD-MAPPING.md): macOS controls are 36pt, web 44px (§5, §8, §11.3); Control.paddingX 14 is the kit .sm padding (§5). Every other difference is a FAIL. The 44pt StepFlow rule in §8 is not followed by TBDStepFlow or by Chat, so those rows are FAIL.",
    "The two dark columns use the proposed dark tokens. Hover, pressed and focus states are not part of this proof.",
  ];
  // Links from the page to the images and the kit tokens.css are relative to wherever the page is written.
  const rel = (to: string): string => relative(dirname(pagePath), to).split(sep).join("/");
  writeFileSync(pagePath, page({ results, total, findings, imgDir: rel(outDir), tokensHref: rel(join(kit, "tokens.css")), generated, notes }));

  console.log(`design-sameness: ${CELLS.length} components, ${total.pass} PASS, ${total.documented} DOCUMENTED, ${total.fail} FAIL, ${total.na} N/A cells`);
  for (const r of results) console.log(`  ${r.cell.id.padEnd(10)} pass ${r.counts.pass}  documented ${r.counts.documented}  fail ${r.counts.fail}  n/a cells ${r.counts.na}`);
  console.log(`  ${outDir}\n  ${pagePath}`);
  if (strict && total.fail > 0) process.exit(1);
}

main().catch((e) => { console.error(e); process.exit(1); });
