/* design-tokens.ts — ONE source for TBD's design values (C139).
   Reads design/tokens.ts (a verbatim copy of the Tealbrick toolkit tokens.ts) and writes:
     native/Sources/TBDDesign/TBDTokens.swift   SwiftUI tokens (kit names + the legacy TBDTokens names)
     chat/src/renderer/src/tbd-tokens.css       Chat tokens (the web --tb-* names, light + dark)
   Usage (from chat/):
     node scripts/design-tokens.ts                 regenerate both files
     node scripts/design-tokens.ts --check         exit 1 if a generated file is stale (CI, via npm run lint)
     node scripts/design-tokens.ts --sync <path>   copy a newer toolkit tokens.ts into design/, then regenerate
   Unknown colour syntax fails loudly: a new toolkit form must be taught here, never guessed. */
import { createHash } from "node:crypto";
import { copyFileSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const repo = join(import.meta.dirname, "..", "..");
const source = join(repo, "design", "tokens.ts");
const outSwift = join(repo, "native", "Sources", "TBDDesign", "TBDTokens.swift");
const outCss = join(repo, "chat", "src", "renderer", "src", "tbd-tokens.css");

const args = process.argv.slice(2);
const syncAt = args.indexOf("--sync");
if (syncAt >= 0) {
  const from = args[syncAt + 1];
  if (!from) throw new Error("--sync needs the path of the toolkit tokens.ts");
  copyFileSync(from, source);
}

type Kit = {
  tokens: Record<string, string>;
  dark: Record<string, string>;
  resolved: Record<string, string>;
  resolvedDark: Record<string, string>;
};
const kit = (await import(source)) as Kit;
const text = readFileSync(source, "utf8");
const sha = createHash("sha256").update(text).digest("hex");
// 0.1.x web aliases carry a @deprecated doc comment in tokens.ts; TBD never used them.
const deprecated = new Set([...text.matchAll(/@deprecated[^\n]*\n\s*([a-zA-Z0-9]+):/g)].map((m) => m[1]));
const names = Object.keys(kit.tokens).filter((k) => !deprecated.has(k));
const kebab = (k: string): string => k.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`);

// ---------------------------------------------------------------- colours
type RGBA = [number, number, number, number];
const parseColour = (raw: string): RGBA | null => {
  const v = raw.trim();
  if (v === "transparent") return [0, 0, 0, 0];
  let m = /^#([0-9a-f]{6})$/i.exec(v);
  if (m) return [0, 2, 4].map((i) => Number.parseInt(m![1].slice(i, i + 2), 16)).concat(1) as RGBA;
  m = /^rgb\(\s*(\d+)\s+(\d+)\s+(\d+)\s*(?:\/\s*([\d.]+%?))?\s*\)$/.exec(v);
  if (m) {
    const a = m[4] === undefined ? 1 : m[4].endsWith("%") ? Number.parseFloat(m[4]) / 100 : Number.parseFloat(m[4]);
    return [Number(m[1]), Number(m[2]), Number(m[3]), a];
  }
  // color-mix(in <space>, <colour> p%, transparent) = the colour at alpha p (premultiplied mix with transparent).
  m = /^color-mix\(in [a-z]+,\s*(.+?)\s+([\d.]+)%,\s*transparent\)$/.exec(v);
  if (m) {
    const c = parseColour(m[1]);
    if (c) return [c[0], c[1], c[2], c[3] * (Number.parseFloat(m[2]) / 100)];
  }
  if (/^(#|rgb|hsl|color-mix|oklch|oklab|color\()/.test(v)) throw new Error(`design-tokens: unsupported colour syntax "${v}"`);
  return null;
};
const colourNames = names.filter((k) => parseColour(kit.resolved[k]) !== null);

// ---------------------------------------------------------------- numbers (points: 1rem = 16pt; seconds)
const num = (v: string): number | null => {
  const m = /^(-?[\d.]+)(px|rem|ms)?$/.exec(v.trim());
  if (!m) return null;
  const n = Number.parseFloat(m[1]);
  return m[2] === "rem" ? n * 16 : m[2] === "ms" ? n / 1000 : n;
};
const fmt = (n: number): string => (Number.isInteger(n) ? String(n) : String(Math.round(n * 10000) / 10000));
const sizeNames = names.filter((k) => !colourNames.includes(k) && /(px|rem)$/.test(kit.resolved[k].trim()) && num(kit.resolved[k]) !== null);
const durNames = names.filter((k) => /^dur/.test(k));
const easeNames = names.filter((k) => /^ease/.test(k));
const weightNames = names.filter((k) => /^weight/.test(k));
const unitless = names.filter((k) => /^(leading|tracking)/.test(k));
const bezier = (v: string): number[] => {
  const m = /^cubic-bezier\(([^)]+)\)$/.exec(v.trim());
  if (!m) throw new Error(`design-tokens: easing is not a cubic-bezier: ${v}`);
  return m[1].split(",").map((x) => Number.parseFloat(x));
};
const swiftWeight: Record<string, string> = { "400": ".regular", "700": ".bold", "800": ".heavy", "900": ".black" };

// The float shadow (`0 0 0 <hair> line, 0 <y> <blur> <spread> shadowInk`). SwiftUI has no spread:
// radius = (blur + spread) / 2 and y = y + spread / 2 keep the same visible footprint.
const float = /0 (\d+)px (\d+)px (-?\d+)px/.exec(kit.tokens.shadowFloat);
if (!float) throw new Error(`design-tokens: unexpected shadowFloat ${kit.tokens.shadowFloat}`);
const [fy, fblur, fspread] = float.slice(1).map(Number);

// ---------------------------------------------------------------- TBD roles (the mapping in coordination/design/TBD-MAPPING.md)
/** Legacy TBDTokens colour names (used by ~120 native files) → kit colour. Call sites stay; values change. */
const legacy: [string, string, string][] = [
  ["canvas", "paper", "window ground"],
  ["paper", "tile", "cards, fields and sheets (the kit's tile)"],
  ["ink", "ink", "words"],
  ["muted", "muted", "secondary text"],
  ["border", "line", "hairlines and card rings; control edges use TBDColor.fieldEdge"],
  ["selected", "tealWash", "selected rows"],
  ["hover", "plate", "hovered rows"],
  ["onPrimary", "primaryOn", "text on the primary fill"],
  ["alert", "brickInk", "risk text and destructive labels (readable twin of brick)"],
  ["accent", "tealInk", "teal text, icons and marks (readable twin of teal)"],
  ["fill", "primaryFill", "the primary action fill (ink; hover teal-deep)"],
];
const dataSeries = ["toneTeal", "toneMoss", "toneWood", "toneBrick", "toneStone", "inkSoft"];
/** TBD type roles → kit ramp (size token, weight token). TBD panes are dense: body = the 15pt label size (DESIGN-SYSTEM §3.2). */
const typeRoles: [string, string, string, string][] = [
  ["display", "textH2", "weightHead", "page titles"],
  ["title", "textTitle", "weightLabel", "section and card titles"],
  ["body", "textLabel", "weightBody", "reading text in dense panes"],
  ["control", "textControl", "weightLabel", "every control label (buttons, fields, selects)"],
  ["label", "textHint", "weightLabel", "small sentence-case labels (no uppercase, no mono)"],
  ["hint", "textTag", "weightBody", "help text under a field"],
  ["tag", "textTag", "weightNav", "pills: tags, chips, counts, segmented"],
];
for (const [, size, weight] of typeRoles) if (!(size in kit.resolved) || !(weight in kit.resolved)) throw new Error(`design-tokens: missing ${size}/${weight}`);
for (const [, to] of legacy) if (!colourNames.includes(to)) throw new Error(`design-tokens: legacy target ${to} is not a colour`);

const hex = (c: RGBA): string => `0x${c.slice(0, 3).map((x) => Math.round(x).toString(16).padStart(2, "0").toUpperCase()).join("")}`;
const swiftColour = (k: string): string => {
  const l = parseColour(kit.resolved[k])!;
  const d = parseColour(kit.resolvedDark[k])!;
  return `dynamic(${hex(l)}, ${fmt(l[3])}, ${hex(d)}, ${fmt(d[3])})`;
};

const swift = `// GENERATED by chat/scripts/design-tokens.ts from design/tokens.ts — do not edit by hand.
// Toolkit tokens.ts sha256 ${sha}
// Regenerate: cd chat && node scripts/design-tokens.ts   (CI fails when this file is stale)
import AppKit
import SwiftUI

/// Kit colours with the web --tb-* names (light and dark, resolved). State colours are pairs: \`xFill\` + \`xOn\` (+ \`xEdge\`).
public enum TBDColor {
${colourNames.map((k) => `    /// --tb-${kebab(k)}\n    public static let ${k} = ${swiftColour(k)}`).join("\n")}

    /// The light ink and paper, fixed in both appearances: floating overlays over arbitrary desktop content
    /// (recording / meeting indicator) keep a dark ground so white indicators stay readable.
    public static let overlayFill = dynamic(${hex(parseColour(kit.resolved.ink)!)}, 1, ${hex(parseColour(kit.resolved.ink)!)}, 1)
    public static let overlayOn = dynamic(${hex(parseColour(kit.resolved.paper)!)}, 1, ${hex(parseColour(kit.resolved.paper)!)}, 1)

    /// Every colour by its kit name (rendered audits classify drawn pixels by token).
    public static let all: [(name: String, color: Color)] = [
${colourNames.map((k) => `        ("${k}", ${k}),`).join("\n")}
    ]

    static func dynamic(_ light: UInt32, _ lightAlpha: CGFloat, _ dark: UInt32, _ darkAlpha: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(dark, darkAlpha) : rgb(light, lightAlpha)
        })
    }
    private static func rgb(_ v: UInt32, _ a: CGFloat) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: a)
    }
}

/// Kit sizes in points (1rem = 16pt), unitless leading/tracking (em), durations in seconds, easings as cubic-bezier.
public enum TBDKit {
${sizeNames.map((k) => `    public static let ${k}: CGFloat = ${fmt(num(kit.resolved[k])!)}`).join("\n")}
${unitless.map((k) => `    public static let ${k}: CGFloat = ${fmt(Number.parseFloat(kit.resolved[k]))}`).join("\n")}
${weightNames.map((k) => `    public static let ${k}: Font.Weight = ${swiftWeight[kit.resolved[k]] ?? (() => { throw new Error(`weight ${kit.resolved[k]}`); })()}`).join("\n")}
${durNames.map((k) => `    public static let ${k}: Double = ${fmt(num(kit.resolved[k])!)}`).join("\n")}
${easeNames.map((k) => `    public static let ${k}: (Double, Double, Double, Double) = (${bezier(kit.resolved[k]).map(fmt).join(", ")})`).join("\n")}
    /// --tb-shadow-float as SwiftUI: radius = (blur + spread) / 2, y = y + spread / 2, colour --tb-shadow-ink, plus a hair ring in line.
    public static let floatShadowRadius: CGFloat = ${fmt((fblur + fspread) / 2)}
    public static let floatShadowY: CGFloat = ${fmt(fy + fspread / 2)}
}

/// TBD's established token names. They keep their call sites; their values now come from the kit.
public enum TBDTokens {
${legacy.map(([from, to, why]) => `    /// ${why} → TBDColor.${to}\n    public static var ${from}: Color { TBDColor.${to} }`).join("\n")}

    /// Categories and charts (never chrome): the kit's group tones, plum → ink-soft.
    public static let data: [Color] = [${dataSeries.map((k) => `TBDColor.${k}`).join(", ")}]

    /// C125/C126: ONE brick radius for everything you act with or that holds content; pills use Capsule().
    public enum Radius {
        public static let brick: CGFloat = TBDKit.radiusBrick
        public static let swatch: CGFloat = TBDKit.radiusSwatch
        public static let base: CGFloat = TBDKit.radiusBrick
        public static let xs: CGFloat = TBDKit.radiusBrick
        public static let sm: CGFloat = TBDKit.radiusBrick
    }
    public enum Stroke {
        public static let hairline: CGFloat = TBDKit.hair
        public static let bar: CGFloat = 2
        public static let focus: CGFloat = TBDKit.focusWidth
    }
    public enum Space {
        public static let xs: CGFloat = TBDKit.s1
        public static let sm: CGFloat = TBDKit.s2
        public static let md: CGFloat = TBDKit.s3
        public static let lg: CGFloat = TBDKit.s4
        public static let xl: CGFloat = TBDKit.s5
        public static let xxl: CGFloat = TBDKit.s6
        public static let xxxl: CGFloat = TBDKit.s8
    }
    public struct HardShadow: Sendable { public let x: CGFloat; public let y: CGFloat; public let opacity: Double }
    /// One Lift Rule: nothing in the flow casts a hard offset shadow. Kept at zero so old call sites draw nothing.
    public enum Shadow {
        public static let brickSm = HardShadow(x: 0, y: 0, opacity: 0)
        public static let brickMd = HardShadow(x: 0, y: 0, opacity: 0)
        public static let brickLg = HardShadow(x: 0, y: 0, opacity: 0)
    }
    /// macOS is pointer-only: controls are 36pt (the kit's small control); the main action of a form may use 44pt (--tb-target).
    public enum Control {
        public static let minHeight: CGFloat = 36
        public static let largeHeight: CGFloat = TBDKit.target
        public static let paddingX: CGFloat = 14
    }
    public enum Typography {
${typeRoles.map(([role, size, weight, why]) => `        /// ${why}: ${fmt(num(kit.resolved[size])!)}pt / ${kit.resolved[weight]}\n        public static var ${role}: Font { TBDFonts.nunito(TBDKit.${size}, TBDKit.${weight}) }`).join("\n")}
        public static var mono: Font { .system(size: TBDKit.textHint, design: .monospaced) }
        public static let displayTracking: CGFloat = TBDKit.textH2 * TBDKit.trackingHead
        public static let titleTracking: CGFloat = 0
        public static let bodyTracking: CGFloat = 0
        public static let controlTracking: CGFloat = 0
        public static let labelTracking: CGFloat = 0
    }
}
`;

const cssBlock = (map: Record<string, string>, keys: string[]): string => keys.map((k) => `  --tb-${kebab(k)}: ${map[k]};`).join("\n");
const darkKeys = Object.keys(kit.dark).filter((k) => !deprecated.has(k));
/** Chat's earlier --tbd-* names → kit tokens, so rules that still read them follow the kit (shrinks with the guard baseline). */
const cssLegacy: [string, string][] = [
  ...legacy.map(([from, to]) => [kebab(from), `var(--tb-${kebab(to)})`] as [string, string]),
  ["sidebar", "var(--tb-paper)"],
  ...dataSeries.map((k, i) => [`data-${["teal", "moss", "ochre", "clay", "slate", "plum"][i]}`, `var(--tb-${kebab(k)})`] as [string, string]),
  ["radius-base", "var(--tb-radius-brick)"],
  ["radius-xs", "var(--tb-radius-brick)"],
  ["radius-sm", "var(--tb-radius-brick)"],
  ...["xs", "sm", "md", "lg", "xl", "xxl", "xxxl"].map((s, i) => [`space-${s}`, `var(--tb-s${[1, 2, 3, 4, 5, 6, 8][i]})`] as [string, string]),
  ["shadow-brick-sm", "none"],
  ["shadow-brick-md", "var(--tb-shadow-float)"],
  ["shadow-brick-lg", "var(--tb-shadow-float)"],
  ["control-height", "36px"],
  ["control-pad", "14px"],
  ["font-display", "var(--tb-font)"],
  ["font-body", "var(--tb-font)"],
  ["font-mono", "var(--tb-font-mono)"],
  ["motion-instant", "var(--tb-dur-exit) var(--tb-ease)"],
  ["motion-quick", "var(--tb-dur-fast) var(--tb-ease)"],
  ["motion-standard", "var(--tb-dur) var(--tb-ease)"],
  ["motion-spring", "var(--tb-dur-slow) var(--tb-ease)"],
  ["motion-gentle", "var(--tb-dur-slow) var(--tb-ease)"],
];

const css = `/* GENERATED by chat/scripts/design-tokens.ts from design/tokens.ts — do not edit by hand.
   Toolkit tokens.ts sha256 ${sha}
   The web --tb-* tokens (light), the dark overrides under data-appearance="dark" (set by the native host),
   the self-hosted Nunito (SIL OFL 1.1, brand/Nunito-OFL.txt) and chat's earlier --tbd-* names as aliases. */
@font-face { font-family: "Nunito"; src: url("./brand/Nunito-VariableFont_wght.ttf") format("truetype"); font-weight: 200 1000; font-style: normal; font-display: swap; }
:root {
${cssBlock(kit.tokens, names)}
}
:root[data-appearance="dark"] {
${cssBlock(kit.dark, darkKeys)}
}
:root {
${cssLegacy.map(([k, v]) => `  --tbd-${k}: ${v};`).join("\n")}
}
`;

const outputs: [string, string][] = [
  [outSwift, swift],
  [outCss, css],
];
if (args.includes("--check")) {
  const stale = outputs.filter(([p, body]) => {
    try {
      return readFileSync(p, "utf8") !== body;
    } catch {
      return true;
    }
  });
  for (const [p] of stale) console.error(`design-tokens: ${p.slice(repo.length + 1)} is stale. Run: cd chat && node scripts/design-tokens.ts`);
  if (stale.length) process.exit(1);
  console.log(`design-tokens: generated files match design/tokens.ts (${sha.slice(0, 12)})`);
} else {
  for (const [p, body] of outputs) writeFileSync(p, body);
  console.log(`design-tokens: ${colourNames.length} colours, ${sizeNames.length} sizes, ${darkKeys.length} dark overrides → TBDTokens.swift, tbd-tokens.css`);
}
