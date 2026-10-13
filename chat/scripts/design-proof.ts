/* design-proof.ts: dev-only screenshots + rendered contrast audit of the real TBD Chat renderer.
   Run (from chat/): node scripts/design-proof.ts <outDir> [--prefix tbd-chat] [--no-fail]
   - Starts a Vite dev server on scripts/design-proof/ (the real App on a fake window.studio).
   - Headless Chrome via playwright-core (PW_CORE, default: the read-only website checkout; CHROME_PATH optional).
   - For light and dark (data-appearance + color-scheme on <html>, as the native host does) writes
       <prefix>-<theme>.png, <prefix>-composer-focus-<theme>.png, <prefix>-agents-hover-<theme>.png
     and audits text (AA 4.5, large 3.0) and focus indicators (3.0) in each state.
   - Writes <prefix>-contrast.json; exit 1 on any failure unless --no-fail.
   The in-page audit is ported from coordination/design/tools/screens.ts. */
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import react from "@vitejs/plugin-react";
import { createServer } from "vite";

const PW = process.env.PW_CORE ?? "/Users/puma/work/active/website-martin-redesign/node_modules/playwright-core/index.mjs";
const args = process.argv.slice(2);
const flag = (name: string): string | undefined => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined; };
const prefix = flag("--prefix") ?? "tbd-chat";
const noFail = args.includes("--no-fail");
const outDir = resolve(args.find((a, i) => !a.startsWith("--") && args[i - 1] !== "--prefix") ?? "design-proof-out");
mkdirSync(outDir, { recursive: true });

interface Finding { kind: "text" | "focus"; where: string; text: string; fg: string; bg: string; ratio: number; required: number }
type Audit = { checked: number; findings: Finding[] };

/** Runs in the page. Composited contrast of every visible text node and every focus indicator. */
const audit = (dark: boolean): Audit => {
  const cv = document.createElement("canvas"); cv.width = cv.height = 1;
  const cx = cv.getContext("2d", { willReadFrequently: true }) as CanvasRenderingContext2D;
  const rgba = (c: string): number[] => { cx.clearRect(0, 0, 1, 1); cx.fillStyle = "#000"; cx.fillStyle = c; cx.fillRect(0, 0, 1, 1); const d = cx.getImageData(0, 0, 1, 1).data; return [d[0], d[1], d[2], d[3] / 255]; };
  const mix = (f: number[], a: number, b: number[]): number[] => [0, 1, 2].map((i) => f[i] * a + b[i] * (1 - a));
  const lum = (c: number[]): number => { const f = (v: number) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; }; return 0.2126 * f(c[0]) + 0.7152 * f(c[1]) + 0.0722 * f(c[2]); };
  const ratio = (a: number[], b: number[]): number => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };
  const opacityOf = (el: Element | null): number => { let o = 1; for (let e = el; e; e = e.parentElement) o *= parseFloat(getComputedStyle(e).opacity); return o; };
  // Page canvas under everything: Chromium paints its own canvas when no ancestor is opaque.
  const canvas = dark ? [18, 18, 18] : [255, 255, 255];
  const bgOf = (el: Element | null): number[] => {
    const layers: number[][] = [];
    for (let e = el; e; e = e.parentElement) { const c = rgba(getComputedStyle(e).backgroundColor); if (c[3] > 0) { layers.push(c); if (c[3] >= 1) break; } }
    let col = canvas;
    for (const l of layers.reverse()) col = mix(l, l[3], col);
    return col;
  };
  const css = (c: number[]): string => `rgb(${c.map((v) => Math.round(v)).join(",")})`;
  const round = (n: number): number => Math.round(n * 100) / 100;
  const path = (el: Element): string => {
    const parts: string[] = [];
    for (let e: Element | null = el; e && e !== document.body && parts.length < 4; e = e.parentElement) {
      parts.unshift(`${e.tagName.toLowerCase()}${e.id ? `#${e.id}` : ""}${[...e.classList].slice(0, 2).map((c) => `.${c}`).join("")}`);
    }
    return parts.join(" > ");
  };
  const findings: Finding[] = [];
  let checked = 0;
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  const seen = new Set<Element>();
  for (let n = walker.nextNode(); n; n = walker.nextNode()) {
    const el = n.parentElement;
    if (!el || seen.has(el) || !(n.textContent ?? "").trim() || el.closest("svg, script, style, noscript, [hidden]")) continue;
    const cs = getComputedStyle(el);
    if (cs.visibility === "hidden" || cs.display === "none" || el.getClientRects().length === 0) continue;
    const r = el.getBoundingClientRect(); if (r.width < 1 || r.height < 1) continue;
    seen.add(el);
    const op = opacityOf(el); if (op < 0.05) continue;
    const bg = bgOf(el); const fgc = rgba(cs.color);
    const fg = mix(fgc, fgc[3] * op, bg);
    const size = parseFloat(cs.fontSize), w = parseInt(cs.fontWeight, 10);
    const required = size >= 24 || (size >= 18.66 && w >= 700) ? 3 : 4.5;
    const rt = ratio(fg, bg); checked++;
    if (rt < required) findings.push({ kind: "text", where: path(el), text: (el.textContent ?? "").trim().slice(0, 50), fg: css(fg), bg: css(bg), ratio: round(rt), required });
  }
  // Focus: outlines (>= 2px) on :focus-visible elements, as screens.ts. Beyond it, the focused
  // element or one of its ancestors up to 4 levels must show SOME indicator (outline, box-shadow
  // ring or border) at >= 3:1 against its surroundings; otherwise keyboard focus is invisible.
  const active = document.activeElement;
  if (active && active !== document.body && active.matches(":focus-visible")) {
    checked++;
    let best = 0, bestFg = "none", bestBg = "none";
    let el: Element | null = active;
    for (let i = 0; el && el !== document.body && i < 5; i++, el = el.parentElement) {
      if (i > 0 && !el.matches(":focus-within")) break;
      const cs = getComputedStyle(el);
      const bg = bgOf(el.parentElement);
      const cands: string[] = [];
      if (cs.outlineStyle !== "none" && parseFloat(cs.outlineWidth) >= 1) cands.push(cs.outlineColor);
      for (const m of cs.boxShadow.matchAll(/(rgba?\([^)]*\)|#[0-9a-f]{3,8})\s+(-?[\d.]+)px\s+(-?[\d.]+)px\s+([\d.]+)px(?:\s+(-?[\d.]+)px)?/gi)) {
        if (parseFloat(m[5] ?? "0") >= 1) cands.push(m[1]); // a ring: spread >= 1px (inset rings count too)
      }
      if (parseFloat(cs.borderTopWidth) >= 1 && cs.borderTopStyle !== "none") cands.push(cs.borderTopColor);
      for (const c of cands) {
        const oc = rgba(c); const fg = mix(oc, oc[3], bg); const rt = ratio(fg, bg);
        if (rt > best) { best = rt; bestFg = css(fg); bestBg = css(bg); }
      }
    }
    if (best < 3) findings.push({ kind: "focus", where: path(active), text: "focus indicator", fg: bestFg, bg: bestBg, ratio: round(best), required: 3 });
  }
  return { checked, findings };
};

// Vite dev server: same plugin and aliases as scripts/build-tbd.ts; the app root is design-proof/.
const chatRoot = resolve(import.meta.dirname, "..");
const cacheDir = mkdtempSync(join(tmpdir(), "tbd-design-proof-"));
const server = await createServer({
  configFile: false,
  root: resolve(chatRoot, "scripts/design-proof"),
  publicDir: resolve(chatRoot, "src/renderer/public"), // ./brand/* (fonts, logo)
  cacheDir,
  logLevel: "warn",
  clearScreen: false,
  plugins: [react()],
  resolve: { alias: { "@": resolve(chatRoot, "src/renderer/src"), "@shared": resolve(chatRoot, "src/shared") } },
  server: { host: "127.0.0.1", port: 0, hmr: false, fs: { allow: [chatRoot] } },
});

let browser: { close(): Promise<void> } | undefined;
const failures: (Finding & { theme: string; state: string })[] = [];
let checked = 0;
let exitCode = 0;
try {
  await server.listen();
  const addr = server.httpServer?.address();
  if (!addr || typeof addr === "string") throw new Error("Vite did not report a port");
  const url = `http://127.0.0.1:${addr.port}/`;

  const { chromium } = await import(PW);
  const launched = await chromium.launch({ ...(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : { channel: "chrome" }) });
  browser = launched;
  const ctx = await launched.newContext({ viewport: { width: 1280, height: 800 }, deviceScaleFactor: 2, reducedMotion: "reduce" });
  const page = await ctx.newPage();
  const pageErrors: string[] = [];
  page.on("response", (r: { status(): number; url(): string }) => { if (r.status() >= 400) pageErrors.push(`${r.status()} ${r.url()}`); });
  page.on("pageerror", (e: Error) => pageErrors.push(e.message));
  page.on("console", (m: { type(): string; text(): string }) => { if (m.type() === "error") pageErrors.push(m.text()); });
  await page.goto(url, { waitUntil: "networkidle" });
  // The main view: sidebar roster + thread + composer (not sign-in, workspace picker or the empty roster).
  await page.waitForSelector(".composer__input", { timeout: 20_000 });
  await page.waitForSelector(".row--agent >> nth=3", { timeout: 20_000 });

  const settle = (): Promise<unknown> => page.evaluate(() => document.fonts.ready.then(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(r, 120))))));
  const record = async (theme: string, state: string): Promise<void> => {
    const r: Audit = await page.evaluate(audit, theme === "dark");
    checked += r.checked;
    for (const f of r.findings) failures.push({ theme, state, ...f });
  };
  /** Bounding box of `sel` grown by `margin`, clamped to the 1280x800 viewport. */
  const clipOf = async (sel: string, margin: number, extraRight = 0): Promise<{ x: number; y: number; width: number; height: number }> => {
    const b = await page.locator(sel).first().boundingBox();
    if (!b) throw new Error(`no box for ${sel}`);
    const x = Math.max(0, b.x - margin), y = Math.max(0, b.y - margin);
    return { x, y, width: Math.min(1280, b.x + b.width + margin + extraRight) - x, height: Math.min(800, b.y + b.height + margin) - y };
  };

  for (const theme of ["light", "dark"]) {
    // Exactly what the native host does to switch appearance.
    await page.evaluate((t) => { document.documentElement.dataset.appearance = t; document.documentElement.style.colorScheme = t; }, theme);
    await page.mouse.move(0, 0);
    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
    await settle();
    await page.screenshot({ path: join(outDir, `${prefix}-${theme}.png`) });
    await record(theme, "default");

    await page.locator(".composer__input").focus(); // contenteditable: matches :focus-visible, and the composer :focus-within
    await settle();
    await page.screenshot({ path: join(outDir, `${prefix}-composer-focus-${theme}.png`), clip: await clipOf(".composer", 24) });
    await record(theme, "composer-focus");
    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());

    const row = await page.locator(".row--agent").nth(1).boundingBox();
    if (!row) throw new Error("second agent row not found");
    await page.mouse.move(row.x + row.width / 2, row.y + row.height / 2);
    await settle();
    // The rail tooltip (.rail-name-rollout) sits to the right of the sidebar; keep it in the clip.
    await page.screenshot({ path: join(outDir, `${prefix}-agents-hover-${theme}.png`), clip: await clipOf(".sidebar", 0, 420) });
    await record(theme, "agents-hover");
    await page.mouse.move(0, 0);
  }
  if (pageErrors.length) console.warn(`design-proof: ${pageErrors.length} page error(s), first: ${pageErrors[0]}`);

  // De-duplicate the same finding seen in several states of one theme.
  const merged = new Map<string, Finding & { theme: string; state: string }>();
  for (const f of failures) {
    const key = `${f.theme}|${f.kind}|${f.where}|${f.text}`;
    const seen = merged.get(key);
    if (seen) seen.state += `,${f.state}`; else merged.set(key, { ...f });
  }
  const uniq = [...merged.values()];
  const byTheme = (t: string): number => uniq.filter((f) => f.theme === t).length;
  const summary = { checked, failures: uniq.length, light: byTheme("light"), dark: byTheme("dark"), text: uniq.filter((f) => f.kind === "text").length, focus: uniq.filter((f) => f.kind === "focus").length };
  writeFileSync(join(outDir, `${prefix}-contrast.json`), `${JSON.stringify({ when: new Date().toISOString(), summary, failures: uniq }, null, 2)}\n`);
  console.log(`design-proof: ${checked} checks, ${summary.failures} failures (light ${summary.light}, dark ${summary.dark}; text ${summary.text}, focus ${summary.focus})`);
  console.log(`design-proof: wrote ${join(outDir, `${prefix}-contrast.json`)}`);
  if (uniq.length && !noFail) exitCode = 1;
} catch (e) {
  console.error(`design-proof: ${e instanceof Error ? e.stack ?? e.message : String(e)}`);
  exitCode = 2;
} finally {
  await browser?.close().catch(() => undefined);
  await server.close().catch(() => undefined);
  rmSync(cacheDir, { recursive: true, force: true });
}
process.exit(exitCode);
