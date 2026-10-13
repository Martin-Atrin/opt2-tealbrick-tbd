/* Mini app art registry for AppIcon / AppMark (PROPOSAL for @opt2-tealbrick/ui/assets).
   Provenance: every still is copied byte-for-byte from production (Eyal's redesign):
     repo Tealbrick/Website-martin, commit c544ef9 (main, merge of feat/re-design), path public/images/miniapps/<slug>@{1x,2x}.webp
     (added in 80d797d "feat/miniapp-art"); names from app/_site/content.ts (GROUPS). 1200×540 and 2400×1080 WebP, drawn
     on spot paper (--tb-spot-paper family); the object sits in the centre ~540px square.
   Brand mark: public/landing/logo-mark@3x.png (108×88, shown at 36×29 by app/_site/parts.tsx:15 as .lp-mark), plus
     logo-32.png, logo-48.png, logo-apple-180.png (site icons since 230c30b). No vector source exists in the repo or its
     history; public/favicon.svg is an unrelated older generic icon and is NOT the brand mark (do not use).
   Animated logos: none exist (searched: all refs/branches of Website-martin incl. claude/hero-watercolor,
     claude/brick-motion-home and 80d797d; public/motion (hyperframes trace only); v1 /Users/puma/work/active/tealbrick
     apps/portal/public; opt2 repos for *.webm/*.lottie/*.apng/*lottie*.json). Production serves only the hero floor and
     workspace films. AppIcon keeps an optional `animated` slot (paused under prefers-reduced-motion). */

export type Group = 'memory' | 'coordination' | 'control' | 'connections' | 'creation';
export type MiniApp = { name: string; slug: string; group: Group; opt2Id?: string };

/** Public names (production, content.ts) — one exception: the Marketplace art is our Connect app, named "Connect". */
export const MINI_APPS: MiniApp[] = [
  { name: 'Knowledge', slug: 'knowledge', group: 'memory', opt2Id: 'knowledge' },
  { name: 'Scribe', slug: 'observer-backfill', group: 'memory' },
  { name: 'Task Board', slug: 'work-ethic-kanban', group: 'coordination', opt2Id: 'kanban' },
  { name: 'Operator Inbox', slug: 'operator-inbox', group: 'coordination', opt2Id: 'inbox' },
  { name: 'Evolving Workflows', slug: 'evolution-workflow-runtime', group: 'coordination', opt2Id: 'evolution' },
  { name: 'Rules & Approvals', slug: 'rules-approvals', group: 'control', opt2Id: 'rules' },
  { name: 'Organization Plane', slug: 'organization-plane', group: 'control', opt2Id: 'fleet' },
  { name: 'Mesh Trust Topology', slug: 'mesh-trust-topology', group: 'control' },
  { name: 'Connect', slug: 'marketplace', group: 'connections', opt2Id: 'connect' },
  { name: 'Local Runtime Bridge', slug: 'local-runtime-bridge', group: 'connections' },
  { name: 'Remote Setup', slug: 'remote-setup', group: 'connections' },
  { name: 'Open Design', slug: 'open-design', group: 'creation' },
  { name: 'Live Artifacts', slug: 'live-artifacts', group: 'creation' },
];

/** opt2 product id → art. Every opt2 app has art; these have art but no opt2 app yet: Scribe, Mesh Trust Topology,
    Local Runtime Bridge, Remote Setup, Open Design, Live Artifacts. */
export const byOpt2Id = Object.fromEntries(MINI_APPS.filter(a => a.opt2Id).map(a => [a.opt2Id, a])) as Record<string, MiniApp>;

/** AppIcon crop rule: square brick, spot-paper ground, the still scaled so its centre square fills the icon.
    >= 48px: the full centre square (background-size auto 100%); 24–32px: 125% (object larger); 16px: 150%. */
export const iconCrop = (size: number) => (size >= 48 ? 100 : size >= 24 ? 125 : 150);
export const stillUrl = (slug: string, density: 1 | 2 = 1) => `assets/apps/${slug}@${density}x.webp`;
