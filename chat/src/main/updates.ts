import { keySetFrom, verifyReleaseIndex, type ReleaseIndexBody } from "@opt2-tealbrick/manifest";

/**
 * TBD's update feed (C24): desktop entries in Platform's signed release index.
 * The helper verifies the envelope with the pinned release key using the one
 * manifest implementation (`verifyReleaseIndex`, CORE §3), then picks the
 * newest TBD desktop release. The native updater downloads, checks sha256 and
 * the code signature, and installs only after the person clicks.
 *
 * `current.version` is the running app's `TBDReleaseVersion` (full semver such as
 * 0.1.0-dev.3), which the native updater passes. `CFBundleShortVersionString` stays
 * 0.1.0 for every 0.1.0 pre-release and must not be used here (C68a).
 */

export const INDEX_URL = "https://github.com/Martin-Atrin/opt2-tealbrick-platform/releases/download/registry/index.json";
export const ENVELOPE_URL = "https://github.com/Martin-Atrin/opt2-tealbrick-platform/releases/download/registry/index.jws";
/** Platform release key (public, registry/keys.json). Rotation ships in a TBD update. */
export const RELEASE_JWKS = { keys: [{ kty: "OKP", crv: "Ed25519", x: "H7nxFrNugQLVOqEXVIB4aOg83Jn19UCosd27fqnoPPI" }] } as const;

export interface DesktopRelease {
  version: string;
  url: string;
  sha256: string;
  minOs: string | null;
  notarized: boolean | null;
  publishedAt: string | null;
}

interface RawRelease {
  product?: string; kind?: string; version?: string; channel?: string;
  artifact?: { url?: string; sha256?: string } | null; minOs?: string | null; notarized?: boolean | null; publishedAt?: string;
}

/**
 * Full semver 2.0 precedence (build metadata ignored): a release ranks above its own
 * pre-releases, dot-separated pre-release identifiers compare numerically when both are
 * numbers (dev.9 < dev.10), numeric < alphanumeric, and a shorter identifier list ranks lower.
 * Also used for plain OS versions such as "14.5". Returns -1, 0 or 1.
 */
export function compareVersions(a: string, b: string): number {
  const parse = (v: string) => {
    const text = v.trim().replace(/^v/i, "").split("+", 1)[0] ?? "";
    const dash = text.indexOf("-");
    const core = dash < 0 ? text : text.slice(0, dash);
    const pre = dash < 0 ? [] : text.slice(dash + 1).split(".");
    return { nums: core.split(".").map((n) => Number.parseInt(n, 10) || 0), pre };
  };
  const x = parse(a), y = parse(b);
  for (let i = 0; i < 3; i++) { const d = (x.nums[i] ?? 0) - (y.nums[i] ?? 0); if (d) return d < 0 ? -1 : 1; }
  if (x.pre.length === 0 || y.pre.length === 0) return x.pre.length === y.pre.length ? 0 : x.pre.length === 0 ? 1 : -1;
  const numeric = /^\d+$/;
  for (let i = 0; i < Math.min(x.pre.length, y.pre.length); i++) {
    const p = x.pre[i] as string, q = y.pre[i] as string;
    if (p === q) continue;
    const pn = numeric.test(p), qn = numeric.test(q);
    if (pn && qn) return Number(p) < Number(q) ? -1 : 1;
    if (pn !== qn) return pn ? -1 : 1;
    return p < q ? -1 : 1;
  }
  return x.pre.length === y.pre.length ? 0 : x.pre.length < y.pre.length ? -1 : 1;
}

export function selectDesktopRelease(body: ReleaseIndexBody, current: { version: string; os: string; channel?: "stable" | "dev" }): DesktopRelease | null {
  const channels = current.channel === "dev" ? ["stable", "dev"] : ["stable"];
  let best: DesktopRelease | null = null;
  for (const r of body.releases as RawRelease[]) {
    if (r.product !== "tbd" || r.kind !== "desktop" || !r.version || !channels.includes(r.channel ?? "")) continue;
    const url = r.artifact?.url, sha = r.artifact?.sha256;
    if (!url || !sha || !url.startsWith("https://")) continue;
    if (r.minOs && compareVersions(current.os, r.minOs) < 0) continue;
    if (compareVersions(r.version, current.version) <= 0) continue;
    if (best && compareVersions(r.version, best.version) <= 0) continue;
    best = { version: r.version, url, sha256: sha.replace(/^sha256:/, ""), minOs: r.minOs ?? null, notarized: r.notarized ?? null, publishedAt: r.publishedAt ?? null };
  }
  return best;
}

export async function checkForUpdate(current: { version: string; os: string; channel?: "stable" | "dev" }, deps: { fetch?: typeof fetch; now?: () => number; jwks?: { keys: readonly unknown[] } } = {}): Promise<DesktopRelease | null> {
  const http = deps.fetch ?? fetch;
  const get = async (url: string) => {
    const res = await http(url, { redirect: "follow", signal: AbortSignal.timeout(30_000) });
    if (!res.ok || !res.url.startsWith("https://")) throw new Error(`Update feed answered ${res.status}.`);
    return res.text();
  };
  const [bodyText, envelope] = await Promise.all([get(INDEX_URL), get(ENVELOPE_URL)]);
  const body = JSON.parse(bodyText) as ReleaseIndexBody;
  const verdict = verifyReleaseIndex(envelope.trim(), body, { now: Math.floor((deps.now ?? Date.now)() / 1000), keys: keySetFrom((deps.jwks ?? RELEASE_JWKS) as never, "tb:releases") });
  if (!verdict.ok) throw new Error("The update feed signature did not verify.");
  return selectDesktopRelease(body, current);
}
