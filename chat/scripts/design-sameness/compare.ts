/* design-sameness/compare.ts: compares the WEB, NATIVE and CHAT measurements, property by property.
   PASS        all columns that can show the property are equal (colours exact; sizes within 0.5px; weights equal;
               font family Nunito)
   DOCUMENTED  the differences are exactly a deviation recorded in design/TBD-MAPPING.md (rule below, with its section)
   FAIL        anything else: a FINDING, listed with the exact values (product CSS and Swift are not changed to pass)
   N/A         the column has no counterpart (kept visible, never counted as a pass) */
import type { Col, Prop, ProbeSpec, Theme } from "./cells.ts";

export type Val = string | number | undefined;
export interface Cell { v: Val; src?: "measured" | "declared" }
/** column -> theme -> probe -> prop -> value */
export type Metrics = Record<Col, Record<Theme, Record<string, Partial<Record<Prop, Cell>>>>>;

export type Status = "pass" | "documented" | "fail" | "na";
export interface Row {
  probe: string;
  prop: Prop;
  status: Status;
  /** Per column: the value in light and dark, or the reason it is not shown. */
  cols: Record<Col, { light?: Val; dark?: Val; src?: "measured" | "declared"; na?: string }>;
  /** DOCUMENTED rule text, or the reason of a FAIL. */
  note?: string;
  /** DOCUMENTED, but Chat and native still differ from each other. */
  catch?: string;
}

const COLOUR: Prop[] = ["bg", "color", "edgeColor"];
const SIZE: Prop[] = ["fontSize", "padL", "padR", "padT", "padB", "height", "width", "radius", "edgeWidth"];

const rgbOf = (c: string): { rgb: string; a: number } => {
  const [rgb, a] = c.split("@");
  return { rgb: rgb.toLowerCase(), a: a === undefined ? 1 : Number(a) };
};

export function equal(prop: Prop, a: Val, b: Val): boolean {
  if (a === undefined || b === undefined) return false;
  if (prop === "fontFamily") return String(a).toLowerCase() === String(b).toLowerCase();
  if (COLOUR.includes(prop)) {
    const x = String(a), y = String(b);
    if (x === y) return true;
    if (x === "transparent" || y === "transparent" || x === "none" || y === "none") return false;
    const p = rgbOf(x), q = rgbOf(y);
    return p.rgb === q.rgb && Math.abs(p.a - q.a) <= 0.01;
  }
  if (prop === "radius" && (a === "pill" || b === "pill")) return a === b;
  if (SIZE.includes(prop)) return Math.abs(Number(a) - Number(b)) <= 0.5;
  return Number(a) === Number(b); // weights
}

interface RuleCtx { probe: string; prop: Prop; col: Col; ref: Val; val: Val; refCol: Col; alt?: Val }
type Rule = (c: RuleCtx) => string | null;

const CONTROLS = new Set(["button-primary", "button-secondary", "field-input", "select-trigger", "tab-current", "tab-idle"]);
const BUTTONS = new Set(["button-primary", "button-secondary"]);

/** The deviations TBD-MAPPING.md records. Anything not here is a finding. */
const RULES: Rule[] = [
  // §5 "control 36", §8 "Controls", §11.3: pointer-only macOS (and Chat) controls are 36 against the kit's 44.
  (c) => c.prop === "height" && CONTROLS.has(c.probe) && c.refCol === "web" && Number(c.ref) === 44 && Number(c.val) === 36 && c.col !== "web"
    ? `macOS controls are 36pt, web 44px (TBD-MAPPING §5, §8, §11.3)${c.alt !== undefined && Number(c.alt) === 36 ? "; 36 is the kit's .sm control" : ""}`
    : null,
  // §5 "controlPad 18 / 14": TBDKit.controlPad (18) is the large control; Control.paddingX (14) is the 36pt control = kit .sm.
  (c) => (c.prop === "padL" || c.prop === "padR") && BUTTONS.has(c.probe) && c.refCol === "web" && Number(c.ref) === 18 && Number(c.val) === 14 && c.col === "native"
    ? "Control.paddingX 14 is the 36pt control's padding, the kit .sm padding; controlPad 18 is for the large control (TBD-MAPPING §5)"
    : null,
];

export function compareProbe(spec: ProbeSpec, m: Metrics, refs: Partial<Record<string, Cell>>): Row[] {
  const rows: Row[] = [];
  for (const prop of spec.props) {
    const cols = {} as Row["cols"];
    for (const col of ["web", "native", "chat"] as Col[]) {
      const miss = spec.missing?.[col];
      const na = spec.na?.[col];
      if (miss) { cols[col] = { na: miss }; continue; }
      if (na?.props.includes(prop)) { cols[col] = { na: na.why }; continue; }
      const l = m[col].light[spec.id]?.[prop], d = m[col].dark[spec.id]?.[prop];
      if (!l && !d) { cols[col] = { na: "not measured" }; continue; }
      cols[col] = { light: l?.v, dark: d?.v, src: l?.src ?? d?.src };
    }
    const avail = (["web", "native", "chat"] as Col[]).filter((c) => !cols[c].na);
    if (avail.length < 2) { rows.push({ probe: spec.id, prop, status: "na", cols }); continue; }
    const refCol: Col = avail.includes("web") ? "web" : avail[0];
    let status: Status = "pass";
    const notes: string[] = [];
    const fails: string[] = [];
    for (const col of avail) {
      if (col === refCol) continue;
      const same = (["light", "dark"] as Theme[]).every((t) => equal(prop, cols[refCol][t], cols[col][t]));
      if (same) continue;
      const lightRef = cols[refCol].light, lightVal = cols[col].light;
      const alt = prop === "height" ? refs[`${spec.id}-sm`]?.v : undefined;
      const rule = (["light", "dark"] as Theme[]).every((t) => equal(prop, lightVal, cols[col][t]))
        ? RULES.map((r) => r({ probe: spec.id, prop, col, ref: lightRef, val: lightVal, refCol, alt })).find((x) => x !== null)
        : null;
      if (rule) { notes.push(`${col}: ${rule}`); if (status === "pass") status = "documented"; }
      else { status = "fail"; fails.push(`${col} differs from ${refCol}`); }
    }
    const row: Row = { probe: spec.id, prop, status, cols };
    if (status === "documented") row.note = notes.join("; ");
    if (status === "fail") row.note = fails.join("; ");
    if (status !== "fail" && avail.includes("native") && avail.includes("chat")) {
      const same = (["light", "dark"] as Theme[]).every((t) => equal(prop, cols.native[t], cols.chat[t]));
      if (!same) row.catch = "Chat and native differ from each other (each matches or is documented against web)";
    }
    rows.push(row);
  }
  return rows;
}

export interface Counts { pass: number; documented: number; fail: number; na: number }
export const emptyCounts = (): Counts => ({ pass: 0, documented: 0, fail: 0, na: 0 });
export function add(c: Counts, rows: Row[]): void { for (const r of rows) c[r.status] += 1; }
