import { keySetFrom, verifyReleaseIndex, type ReleaseIndexBody } from "@opt2-tealbrick/manifest";

/**
 * TBD's update feed (C24): desktop entries in Platform's signed release index.
 * The helper verifies the envelope with the pinned release key using the one
 * manifest implementation (`verifyReleaseIndex`, CORE §3), then picks the
 * newest TBD desktop release. The native updater downloads, checks sha256 and
 * the code signature, and installs only after the person clicks.
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

/** semver compare incl. pre-release (a.b.c < a.b.c-x is false; release > prerelease). */
export function compareVersions(a: string, b: string): number {
  const parse = (v: string) => {
    const [core, pre] = v.replace(/^v/, "").split("-", 2);
    return { nums: core.split(".").map((n) => Number.parseInt(n, 10) || 0), pre: pre ?? null };
  };
  const x = parse(a), y = parse(b);
  for (let i = 0; i < 3; i++) { const d = (x.nums[i] ?? 0) - (y.nums[i] ?? 0); if (d) return d < 0 ? -1 : 1; }
  if (x.pre === y.pre) return 0;
  if (x.pre === null) return 1;
  if (y.pre === null) return -1;
  return x.pre < y.pre ? -1 : 1;
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
