/* design-tokens.ts — ONE source for TBD's design values (C139, C150): the released @opt2-tealbrick/ui package.
   Chat imports the package's tokens.css / components.css / fonts directly. This script reads the SAME package
   (node_modules/@opt2-tealbrick/ui: dist/tokens.js, dist/apps.js, assets/apps/*.webp) and writes:
     native/Sources/TBDDesign/TBDTokens.swift   SwiftUI tokens (kit names + the legacy TBDTokens names)
     native/Sources/TBDDesign/TBDApps.swift     the opt2 mini apps (id, name, slug, group, colour token)
     chat/src/renderer/src/lib/apps.generated.ts   the same apps for Chat
     native/Sources/TBDDesign/Apps/*.webp, chat/src/renderer/public/brand/apps/*.webp   byte copies of the stills
   Usage (from chat/, after npm ci):
     node scripts/design-tokens.ts           regenerate
     node scripts/design-tokens.ts --check   exit 1 if a generated file is stale (CI, via npm run lint)
   The package version is pinned in chat/package.json (+ lock integrity); upgrading it and regenerating is the
   only way design values change. Unknown colour syntax fails loudly: teach it here, never guess. */
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const repo = join(import.meta.dirname, "..", "..");
const pkg = join(repo, "chat", "node_modules", "@opt2-tealbrick", "ui");
const source = join(pkg, "dist", "tokens.js");
const outSwift = join(repo, "native", "Sources", "TBDDesign", "TBDTokens.swift");
const pkgVersion = (JSON.parse(readFileSync(join(pkg, "package.json"), "utf8")) as { version: string }).version;
const args = process.argv.slice(2);

type Kit = {
  cssName: Record<string, string>;
  tokens: Record<string, string>;
  dark: Record<string, string>;
  resolved: Record<string, string>;
  resolvedDark: Record<string, string>;
};
const kit = (await import(source)) as Kit;
const text = readFileSync(source, "utf8");
const sha = createHash("sha256").update(text).digest("hex");
const names = Object.keys(kit.tokens);
/** The package's own css name map (e.g. s8 → s8, textH2 → text-h2). */
const kebab = (k: string): string => kit.cssName[k] ?? k.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`);

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

const swift = `// GENERATED by chat/scripts/design-tokens.ts from @opt2-tealbrick/ui ${pkgVersion} (dist/tokens.js) — do not edit by hand.
// tokens.js sha256 ${sha}
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

// ---------------------------------------------------------------- mini apps (design/apps.ts + design/apps/*.webp)
// The opt2 apps with their production still and their header colour token (--tb-app-<id>, white text).
type PkgApp = { id: string; name: string; group: string; slug: string; colour: string };
const appsJs = join(pkg, "dist", "apps.js");
const pkgApps = Object.values(((await import(appsJs)) as { APPS: Record<string, PkgApp> }).APPS);
const apps = pkgApps.map((a) => {
  const token = `app${a.id[0].toUpperCase()}${a.id.slice(1)}`;
  if (!colourNames.includes(token)) throw new Error(`design-tokens: no colour token ${token} for app ${a.id}`);
  return { id: a.id, name: a.name, slug: a.slug, group: a.group, token };
});
const appsSha = createHash("sha256").update(readFileSync(appsJs)).digest("hex");
const swiftApps = `// GENERATED by chat/scripts/design-tokens.ts from @opt2-tealbrick/ui ${pkgVersion} (dist/apps.js) — do not edit by hand.
// apps.js sha256 ${appsSha}
import SwiftUI

/// One opt2 mini app: its public name, production still (Apps/<slug>@2x.webp), material group and header colour.
public struct TBDApp: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let slug: String
    public let group: String
    /// The kit token for the header colour (white text on it is AA, tools/app-colors.ts).
    public let colorToken: String
    public var color: Color { TBDColor.all.first { $0.name == colorToken }?.color ?? TBDColor.teal }
}

public enum TBDApps {
    public static let all: [TBDApp] = [
${apps.map((a) => `        TBDApp(id: "${a.id}", name: "${a.name}", slug: "${a.slug}", group: "${a.group}", colorToken: "${a.token}"),`).join("\n")}
    ]
    public static func app(_ id: String) -> TBDApp? { all.first { $0.id == id } }
}
`;
const tsApps = `// GENERATED by chat/scripts/design-tokens.ts from @opt2-tealbrick/ui ${pkgVersion} (dist/apps.js) — do not edit by hand.
// apps.js sha256 ${appsSha}
/** One opt2 mini app: public name, production still (brand/apps/<slug>@1x|2x.webp), group and header colour token. */
export type TbdApp = { id: string; name: string; slug: string; group: string; color: string };
export const TBD_APPS: readonly TbdApp[] = [
${apps.map((a) => `  { id: "${a.id}", name: "${a.name}", slug: "${a.slug}", group: "${a.group}", color: "var(--tb-${kebab(a.token)})" },`).join("\n")}
];
export const tbdApp = (id: string): TbdApp | undefined => TBD_APPS.find((a) => a.id === id);
`;
// The stills are copied byte for byte next to each consumer (SwiftPM resources and the Chat public folder).
const stills = apps.flatMap((a) => [1, 2].map((d) => `${a.slug}@${d}x.webp`));
const stillTargets = [join(repo, "native", "Sources", "TBDDesign", "Apps"), join(repo, "chat", "src", "renderer", "public", "brand", "apps")];

const outputs: [string, string | Buffer][] = [
  [outSwift, swift],
  [join(repo, "native", "Sources", "TBDDesign", "TBDApps.swift"), swiftApps],
  [join(repo, "chat", "src", "renderer", "src", "lib", "apps.generated.ts"), tsApps],
  ...stillTargets.flatMap((dir) => stills.map((f) => [join(dir, f), readFileSync(join(pkg, "assets", "apps", f))] as [string, Buffer])),
];
if (args.includes("--check")) {
  const stale = outputs.filter(([p, body]) => {
    try {
      return typeof body === "string" ? readFileSync(p, "utf8") !== body : !readFileSync(p).equals(body);
    } catch {
      return true;
    }
  });
  for (const [p] of stale) console.error(`design-tokens: ${p.slice(repo.length + 1)} is stale. Run: cd chat && node scripts/design-tokens.ts`);
  if (stale.length) process.exit(1);
  console.log(`design-tokens: generated files match @opt2-tealbrick/ui ${pkgVersion} (${sha.slice(0, 12)})`);
} else {
  for (const dir of stillTargets) mkdirSync(dir, { recursive: true });
  for (const [p, body] of outputs) writeFileSync(p, body);
  console.log(`design-tokens: @opt2-tealbrick/ui ${pkgVersion}: ${colourNames.length} colours, ${sizeNames.length} sizes, ${apps.length} apps → TBDTokens.swift, TBDApps.swift, apps.generated.ts`);
}
