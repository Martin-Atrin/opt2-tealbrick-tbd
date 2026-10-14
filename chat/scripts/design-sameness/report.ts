/* design-sameness/report.ts: the static page TBD-SAMENESS.html. Tokens come only from the toolkit's tokens.css
   (relative link). No scripts, no external fonts. Text for Martin is plain, short, active-voice English. */
import type { CellDef, Col, ProbeSpec, Theme } from "./cells.ts";
import { type Counts, type Row, type Status, type Val, emptyCounts } from "./compare.ts";

export interface ComponentResult { cell: CellDef; probes: { spec: ProbeSpec; rows: Row[] }[]; counts: Counts }

const esc = (s: unknown): string => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const PROP: Record<string, string> = {
  fontFamily: "font family", fontSize: "font size", fontWeight: "font weight", lineHeight: "line height",
  padL: "padding left", padR: "padding right", padT: "padding top", padB: "padding bottom",
  height: "height", width: "width", radius: "radius", bg: "fill", color: "text colour", edgeColor: "edge colour", edgeWidth: "edge width",
};
const LABEL: Record<Status, string> = { pass: "PASS", documented: "DOCUMENTED", fail: "FAIL", na: "N/A" };
const px = (p: string, v: Val): string => (v === undefined ? "—" : typeof v === "number" && !["fontWeight"].includes(p) ? (p === "fontSize" ? `${v}` : `${v}`) : String(v));

function cellText(r: Row, col: Col): string {
  const c = r.cols[col];
  if (c.na) return `<span class="na" title="${esc(c.na)}">n/a</span>`;
  const l = px(r.prop, c.light), d = px(r.prop, c.dark);
  const colour = r.prop === "bg" || r.prop === "color" || r.prop === "edgeColor";
  const mark = col === "native" && c.src === "declared" ? '<sup title="declared: the token constant the component is built from">d</sup>' : "";
  return (colour && l !== d ? `${esc(l)}<br><span class="dk">${esc(d)}</span>` : esc(l)) + mark;
}

export function summaryTable(results: ComponentResult[], total: Counts): string {
  const rows = results.map((r) => `<tr><th scope="row"><a href="#c-${r.cell.id}">${esc(r.cell.title)}</a></th><td class="n">${r.counts.pass}</td><td class="n">${r.counts.documented}</td><td class="n${r.counts.fail ? " bad" : ""}">${r.counts.fail}</td><td class="n">${r.counts.na}</td></tr>`).join("");
  return `<table class="sum"><thead><tr><th>Component</th><th>PASS</th><th>DOCUMENTED</th><th>FAIL</th><th>N/A</th></tr></thead><tbody>${rows}</tbody><tfoot><tr><th>Total</th><td class="n">${total.pass}</td><td class="n">${total.documented}</td><td class="n${total.fail ? " bad" : ""}">${total.fail}</td><td class="n">${total.na}</td></tr></tfoot></table>`;
}

function shots(cell: CellDef, dir: string): string {
  const cols: [Col, string][] = [["web", "WEB (kit tokens.css + components.css)"], ["native", "TBD NATIVE (SwiftUI TBDDesign)"], ["chat", "TBD CHAT (Chat renderer CSS)"]];
  const img = (col: Col, t: Theme): string => `<figure><img src="${dir}/${cell.id}-${col}-${t}.png" width="${cell.w}" height="${cell.h}" alt="${esc(cell.title)}, ${col}, ${t}" loading="lazy"></figure>`;
  const block = (t: Theme): string => `<div class="shots ${t}"><p class="theme">${t === "light" ? "Light" : "Dark"}</p><div class="grid" style="--cw:${cell.w}px">${cols.map(([c, label]) => `<div><p class="colh">${esc(label)}</p>${img(c, t)}</div>`).join("")}</div></div>`;
  return block("light") + block("dark");
}

function metricsTable(res: ComponentResult): string {
  const body = res.probes.map(({ spec, rows }) => {
    const head = `<tr class="probe"><th colspan="6">${esc(spec.label)} <code>${esc(spec.id)}</code></th></tr>`;
    const missing = Object.entries(spec.missing ?? {}).map(([c, why]) => `<tr class="note"><td colspan="6">${esc(c.toUpperCase())}: ${esc(why)}</td></tr>`).join("");
    const lines = rows.map((r) => `<tr class="${r.status}"><td>${esc(PROP[r.prop] ?? r.prop)}</td><td>${cellText(r, "web")}</td><td>${cellText(r, "native")}</td><td>${cellText(r, "chat")}</td><td class="st"><span class="badge ${r.status}">${LABEL[r.status]}</span></td><td class="why">${esc([r.note, r.catch ? `Catch: ${r.catch}.` : ""].filter(Boolean).join(" "))}</td></tr>`).join("");
    return head + missing + lines;
  }).join("");
  return `<table class="m"><thead><tr><th>Property</th><th>WEB</th><th>TBD NATIVE</th><th>TBD CHAT</th><th>Result</th><th>Note</th></tr></thead><tbody>${body}</tbody></table>`;
}

export interface Finding { probe: string; prop: string; kind: "FAIL" | "DOCUMENTED, with a catch"; web: string; native: string; chat: string; note: string }

export function findingsTable(findings: Finding[]): string {
  const rows = findings.map((f) => `<tr class="${f.kind === "FAIL" ? "fail" : "documented"}"><td><code>${esc(f.probe)}</code></td><td>${esc(f.prop)}</td><td>${esc(f.web)}</td><td>${esc(f.native)}</td><td>${esc(f.chat)}</td><td><span class="badge ${f.kind === "FAIL" ? "fail" : "documented"}">${esc(f.kind)}</span></td><td class="why">${esc(f.note)}</td></tr>`).join("");
  return `<table class="m"><thead><tr><th>Probe</th><th>Property</th><th>WEB</th><th>NATIVE</th><th>CHAT</th><th>Kind</th><th>Note</th></tr></thead><tbody>${rows}</tbody></table>`;
}

const CSS = `
:root { color-scheme: light; }
body { margin: 0; background: var(--tb-paper); color: var(--tb-ink); font-family: var(--tb-font); font-size: var(--tb-text-label); line-height: 1.55; }
main { max-width: 1280px; margin: 0 auto; padding: var(--tb-s8) var(--tb-gutter) var(--tb-s16); display: grid; gap: var(--tb-s8); }
h1 { margin: 0; font-size: var(--tb-text-h1); font-weight: var(--tb-weight-head); letter-spacing: var(--tb-tracking-head); line-height: 1.05; }
h2 { margin: 0; font-size: var(--tb-text-h2); font-weight: var(--tb-weight-head); letter-spacing: var(--tb-tracking-head); line-height: 1.1; }
h3 { margin: 0; font-size: var(--tb-text-title); font-weight: var(--tb-weight-label); }
p { margin: 0; }
a { color: var(--tb-link); font-weight: var(--tb-weight-nav); }
code { font-family: var(--tb-font-mono); font-size: .875em; color: var(--tb-muted); }
.kicker { color: var(--tb-teal-ink); font-weight: var(--tb-weight-label); }
.lede { color: var(--tb-ink-soft); max-width: 70ch; font-size: var(--tb-text-lede); }
.muted { color: var(--tb-muted); }
section.comp { display: grid; gap: var(--tb-s5); padding-top: var(--tb-s8); box-shadow: var(--tb-rule-top); }
.theme { font-weight: var(--tb-weight-label); color: var(--tb-muted); margin-bottom: var(--tb-s2); }
.grid { display: grid; grid-template-columns: repeat(3, minmax(0, max-content)); gap: var(--tb-s5); align-items: start; }
.colh { font-weight: var(--tb-weight-label); font-size: var(--tb-text-hint); color: var(--tb-ink-soft); margin-bottom: var(--tb-s1); }
figure { margin: 0; }
img { display: block; max-width: 100%; height: auto; border-radius: var(--tb-radius-brick); box-shadow: var(--tb-ring); }
.shots { display: grid; gap: var(--tb-s1); }
table { border-collapse: collapse; width: 100%; font-size: var(--tb-text-hint); background: var(--tb-tile); border-radius: var(--tb-radius-brick); box-shadow: var(--tb-ring); }
th, td { text-align: left; padding: 6px 10px; vertical-align: top; box-shadow: var(--tb-hair-bottom); }
thead th { background: var(--tb-plate); font-weight: var(--tb-weight-label); }
td.n { text-align: right; font-variant-numeric: tabular-nums; }
td.bad, .bad { color: var(--tb-brick-ink); font-weight: var(--tb-weight-label); }
tr.probe th { background: var(--tb-teal-wash); color: var(--tb-teal-ink); font-weight: var(--tb-weight-label); }
tr.note td { color: var(--tb-muted); font-style: normal; }
.m td:nth-child(n+2):nth-child(-n+4) { font-variant-numeric: tabular-nums; white-space: nowrap; }
.dk { color: var(--tb-muted); }
.na { color: var(--tb-muted); border-bottom: var(--tb-hair) dashed var(--tb-line-strong); }
.why { color: var(--tb-ink-soft); max-width: 46ch; }
.badge { display: inline-block; padding: 1px 10px; border-radius: var(--tb-radius-pill); font-weight: var(--tb-weight-label); font-size: var(--tb-text-hint); box-shadow: inset 0 0 0 var(--tb-hair) var(--tb-status-idle-edge); background: var(--tb-status-idle-fill); color: var(--tb-status-idle-on); }
.badge.pass { background: var(--tb-status-live-fill); color: var(--tb-status-live-on); box-shadow: inset 0 0 0 var(--tb-hair) var(--tb-status-live-edge); }
.badge.fail { background: var(--tb-status-needs-you-fill); color: var(--tb-status-needs-you-on); box-shadow: inset 0 0 0 var(--tb-hair) var(--tb-status-needs-you-edge); }
.badge.documented { background: var(--tb-tile); color: var(--tb-ink); box-shadow: inset 0 0 0 var(--tb-hair) var(--tb-line-strong); }
tr.fail td:first-child { box-shadow: inset 3px 0 0 var(--tb-brick), var(--tb-hair-bottom); }
.notes { display: grid; gap: var(--tb-s2); max-width: 90ch; color: var(--tb-ink-soft); }
.notes li { margin-left: var(--tb-s5); }
sup { color: var(--tb-muted); font-weight: var(--tb-weight-label); }
@media (max-width: 960px) { .grid { grid-template-columns: minmax(0, 1fr); } }
`;

export function page(opts: { results: ComponentResult[]; total: Counts; findings: Finding[]; imgDir: string; generated: string; notes: string[] }): string {
  const { results, total, findings, imgDir, generated, notes } = opts;
  const comps = results.map((r) => `<section class="comp" id="c-${r.cell.id}"><h2>${esc(r.cell.title)}</h2><p class="muted">${esc(r.cell.what)}</p><p><span class="badge pass">PASS ${r.counts.pass}</span> <span class="badge documented">DOCUMENTED ${r.counts.documented}</span> <span class="badge fail">FAIL ${r.counts.fail}</span> <span class="badge">N/A ${r.counts.na}</span></p>${shots(r.cell, imgDir)}${metricsTable(r)}</section>`).join("");
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>TBD sameness proof</title>
<link rel="stylesheet" href="tokens.css">
<style>${CSS}</style>
</head>
<body>
<main>
  <header style="display:grid;gap:var(--tb-s3)">
    <p class="kicker">TBD · design proof</p>
    <h1>One design, three renderers</h1>
    <p class="lede">The same ten components, drawn by the web kit, by the native app and by the Chat renderer. Each value is measured, then compared. Generated ${esc(generated)}.</p>
  </header>
  <section style="display:grid;gap:var(--tb-s4)">
    <h2>Summary</h2>
    ${summaryTable(results, total)}
    <p class="muted">PASS: all columns agree (colours exact, sizes within 0.5px, weights equal, Nunito). DOCUMENTED: a deviation that TBD-MAPPING.md records. FAIL: a finding, with the exact values below. N/A: that column has no counterpart.</p>
  </section>
  <section style="display:grid;gap:var(--tb-s4)">
    <h2>Findings</h2>
    ${findings.length ? findingsTable(findings) : "<p>No findings.</p>"}
  </section>
  ${comps}
  <section style="display:grid;gap:var(--tb-s3)">
    <h2>How it works</h2>
    <ul class="notes">${notes.map((n) => `<li>${n}</li>`).join("")}</ul>
  </section>
</main>
</body>
</html>
`;
}

export { emptyCounts };
