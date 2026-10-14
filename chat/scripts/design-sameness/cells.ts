/* design-sameness/cells.ts: the ten components of the TBD sameness proof, as data.
   - markup per column: WEB (the toolkit kit markup, copied from mockups/components.html and build-workspace.ts) and
     CHAT (the markup Chat's own components render; class names read from the TSX and teal-brick.css)
   - the probes (what is measured, which properties are compared, which cells cannot be compared and why)
   The NATIVE column lives in native/Sources/TBDDesignShots/Sameness.swift; its cell sizes must match `w`/`h` here
   (design-sameness.ts checks the PNG size). */

export type Col = "web" | "native" | "chat";
export type Theme = "light" | "dark";
export type Prop =
  | "fontFamily" | "fontSize" | "fontWeight"
  | "padL" | "padR" | "padT" | "padB"
  | "height" | "width" | "radius"
  | "bg" | "color" | "edgeColor" | "edgeWidth" | "lineHeight";

export interface CellDef {
  id: string;
  title: string;
  /** Cell size in CSS px / SwiftUI pt. */
  w: number;
  h: number;
  /** One line: what each column renders, said plainly. */
  what: string;
  web: string;
  chat: string;
  /** Web-only reference probes, measured off-screen (not in the screenshot). */
  refs?: string;
}

export interface ProbeSpec {
  id: string;
  cell: string;
  label: string;
  props: Prop[];
  /** Properties a column cannot show, with the reason (the cell is "n/a", not a pass). */
  na?: Partial<Record<Col, { props: Prop[]; why: string }>>;
  /** The column has no such element at all. */
  missing?: Partial<Record<Col, string>>;
}

const APP_STILL_WEB = "image-set(url(/kit/assets/apps/knowledge@1x.webp) 1x, url(/kit/assets/apps/knowledge@2x.webp) 2x)";
const APP_STILL_CHAT = "image-set(url(./brand/apps/knowledge@1x.webp) 1x, url(./brand/apps/knowledge@2x.webp) 2x)";

const CONTROL: Prop[] = ["fontFamily", "fontSize", "fontWeight", "padL", "padR", "height", "radius", "bg", "color", "edgeColor", "edgeWidth"];
const TEXT: Prop[] = ["fontFamily", "fontSize", "fontWeight", "color"];

export const CELLS: CellDef[] = [
  {
    id: "button", title: "Button", w: 320, h: 76,
    what: "Primary and secondary. Web: .tb-btn (44px). Chat: .btn (36px). Native: TBDButtonStyle regular (36pt).",
    web: `<div class="tb-ctas" style="flex-wrap:nowrap">
  <button class="tb-btn primary" data-m="button-primary"><span class="tb-ink">Primary</span></button>
  <button class="tb-btn" data-m="button-secondary"><span class="tb-ink">Secondary</span></button></div>`,
    chat: `<div style="display:flex;gap:12px">
  <button class="btn btn--primary" data-m="button-primary">Primary</button>
  <button class="btn" data-m="button-secondary">Secondary</button></div>`,
    refs: `<button class="tb-btn primary sm" data-m="button-primary-sm"><span class="tb-ink">Primary</span></button>
  <button class="tb-btn sm" data-m="button-secondary-sm"><span class="tb-ink">Secondary</span></button>`,
  },
  {
    id: "field", title: "Field (label + text input)", w: 320, h: 112,
    what: "Label above a text input. Web: .tb-field. Chat: .field + .input. Native: TBDField.",
    web: `<label class="tb-field" style="width:288px"><span class="tb-label" data-m="field-label">Workspace name</span><input class="tb-input" data-m="field-input" value="Novak Dental"></label>`,
    chat: `<div class="field" style="width:288px"><div class="field__label" data-m="field-label">Workspace name</div><input class="input" data-m="field-input" value="Novak Dental"></div>`,
  },
  {
    id: "select", title: "Select (closed trigger)", w: 320, h: 112,
    what: "Label above the closed trigger. Web: .tb-select-trigger. Chat: the <select> of the sign-in portal picker. Native: TBDSelect.",
    web: `<div class="tb-field" style="width:288px"><span class="tb-label" id="sx-sl" data-m="select-label">Destination</span><div class="tb-select"><button type="button" class="tb-select-trigger" role="combobox" aria-haspopup="listbox" aria-expanded="false" aria-labelledby="sx-sl sx-sv" data-m="select-trigger"><span class="tb-select-value" id="sx-sv">Create new project…</span><span class="tb-chevron" aria-hidden="true"></span></button></div></div>`,
    chat: `<div class="signin__planes" style="width:288px;margin:0"><label for="sx-cp" data-m="select-label">Destination</label><select id="sx-cp" data-m="select-trigger"><option>Create new project…</option><option>studio-sandbox</option></select></div>`,
  },
  {
    id: "card", title: "Card", w: 320, h: 96,
    what: "A card around a fixed 240 × 24 block, so the padding is the card's own. Web: .tb-card. Chat: .card. Native: .tbdCard().",
    web: `<div class="tb-card" data-m="card" style="width:fit-content"><div style="width:240px;height:24px;line-height:24px;color:var(--tb-ink-soft)">Card content</div></div>`,
    chat: `<div class="card" data-m="card" style="width:fit-content"><div style="width:240px;height:24px;line-height:24px;color:var(--tb-ink-soft)">Card content</div></div>`,
  },
  {
    id: "tag", title: "Tag / status", w: 320, h: 60,
    what: "Live and needs-you. Web and Chat: .tb-tag. Native: TBDTag.",
    web: `<div class="tb-row" style="flex-wrap:nowrap"><span class="tb-tag live" data-m="tag-live"><span class="tb-ink">Running</span></span><span class="tb-tag needs-you" data-m="tag-needs-you"><span class="tb-ink">Needs you</span></span></div>`,
    chat: `<div class="tb-row" style="flex-wrap:nowrap"><span class="tb-tag live" data-m="tag-live">Running</span><span class="tb-tag needs-you" data-m="tag-needs-you">Needs you</span></div>`,
  },
  {
    id: "tabs", title: "Tabs", w: 320, h: 76,
    what: "Current and idle tab, 112 wide. Web: .tb-tabs > .tb-tab. Chat: .tab / .tab--on. Native: TBDNavItem (the brick nav item; TBDSegmented is the pill, the kit's .tb-segmented).",
    web: `<nav class="tb-tabs" style="flex-wrap:nowrap"><a class="tb-tab" href="#" aria-current="page" data-m="tab-current" style="width:112px"><span class="tb-ink">Current</span></a><a class="tb-tab" href="#" data-m="tab-idle" style="width:112px"><span class="tb-ink">Other</span></a></nav>`,
    chat: `<div class="modal__tabs" style="padding:0"><button class="tab tab--on" data-m="tab-current" style="width:112px">Current</button><button class="tab" data-m="tab-idle" style="width:112px">Other</button></div>`,
  },
  {
    id: "stepflow", title: "StepFlow", w: 592, h: 632,
    what: "Step row, one step, foot (Previous, Skip, Next), step 2 of 3 current. Web: .tb-dialog.tb-stepflow. Chat: StepFlow.tsx markup without the portal and scrim. Native: TBDStepFlow 560 × 600.",
    web: `<section class="tb-dialog tb-stepflow" role="dialog" aria-label="Add a key" data-m="stepflow">
  <div class="tb-dialog-head"><p class="tb-kicker">Novak Dental</p><button class="tb-close" type="button"><span class="tb-ink">Close</span></button><h2>Add a key</h2>
    <ol class="tb-stepflow-steps" aria-label="Steps"><li class="done" data-m="stepflow-step-done"><button type="button">1-Provider</button></li><li aria-current="step" data-m="stepflow-step-current"><button type="button">2-Key</button></li><li data-m="stepflow-step-upcoming"><button type="button" disabled>3-Model</button></li></ol></div>
  <div class="tb-dialog-body" data-m="stepflow-body"><div class="tb-step"><h3>Add the API key</h3><p class="tb-soft">Add the key now, or skip and add it later.</p></div></div>
  <div class="tb-dialog-foot tb-stepflow-foot" data-m="stepflow-foot"><button class="tb-btn" type="button" data-m="stepflow-prev"><span class="tb-ink">Previous</span></button><button class="tb-btn quiet" type="button"><span class="tb-ink">Skip</span></button><button class="tb-btn primary tb-next" type="button" data-m="stepflow-next"><span class="tb-ink">Next</span></button></div>
</section>`,
    chat: `<section class="tb-dialog tb-stepflow" role="dialog" aria-label="Add a key" tabindex="-1" data-m="stepflow">
  <div class="tb-dialog-head"><p class="tb-kicker">Novak Dental</p><button type="button" class="tb-close">Close</button><h2>Add a key</h2>
    <nav class="tb-stepflow-nav" aria-label="Steps"><ol class="tb-stepflow-steps"><li class="done" data-m="stepflow-step-done"><button type="button">1-Provider</button></li><li aria-current="step" data-m="stepflow-step-current"><button type="button">2-Key</button></li><li data-m="stepflow-step-upcoming"><button type="button" disabled>3-Model</button></li></ol></nav></div>
  <div class="tb-dialog-body" data-m="stepflow-body"><section class="tb-step"><h3 tabindex="-1">Add the API key</h3><p class="tb-soft">Add the key now, or skip and add it later.</p></section></div>
  <div class="tb-dialog-foot tb-stepflow-foot" data-m="stepflow-foot"><button type="button" class="btn" data-m="stepflow-prev">Previous</button><button type="button" class="btn btn--quiet">Skip</button><button type="button" class="btn btn--primary tb-next" data-m="stepflow-next">Next</button></div>
</section>`,
  },
  {
    id: "notice", title: "Notice", w: 360, h: 160,
    what: "Live and needs-you. Web: .tb-notice. Chat has no live or needs-you notice: its nearest are .modal__banner (neutral, shown above) and .modal__banner--error (compared with needs-you). Native: TBDNotice.",
    web: `<div style="display:grid;gap:12px;width:328px"><div class="tb-notice live" data-m="notice-live"><span>Updated and running.</span></div><div class="tb-notice needs-you" data-m="notice-needs-you"><span>Payment failed. Try again.</span></div></div>`,
    chat: `<div style="display:grid;gap:12px;width:328px"><div class="modal__banner" data-m="notice-neutral" style="margin:0">Neutral banner (no live notice in Chat).</div><div class="modal__banner modal__banner--error" data-m="notice-needs-you" style="margin:0">Payment failed. Try again.</div></div>`,
  },
  {
    id: "agentcard", title: "Agent card (canvas, compact)", w: 240, h: 124,
    what: "Initial, name, harness and status. Web: .g-node.is-agent (mockups/build-workspace.ts). Chat: .tbd-agent-card. Native: TBDAgentCard at 208pt.",
    web: `<div class="g-node is-agent" data-m="agent-card" style="position:relative"><div class="row"><span class="avatar" data-m="agent-avatar" aria-hidden="true">F</span><h3 data-m="agent-name">Front desk</h3></div><div class="meta" data-m="agent-meta"><span>Claude Code</span><span class="tb-tag live"><span class="tb-ink">Live</span></span></div></div>`,
    chat: `<div class="tbd-agent-card" data-m="agent-card"><div class="tbd-agent-card__row"><span class="tbd-agent-card__avatar" data-m="agent-avatar" aria-hidden="true">F</span><span class="tbd-agent-card__name" data-m="agent-name">Front desk</span></div><div class="tbd-agent-card__meta" data-m="agent-meta"><span>Claude Code</span><span class="tb-tag live">Live</span></div></div>`,
  },
  {
    id: "appchip", title: "App chip", w: 296, h: 120,
    what: "Web has no app chip: its reference is the app header band of a canvas app card (.g-node.is-app .band) plus the kit's AppIcon 16. Chat: .tbd-app-chip. Native: TBDAppChip. Below each: AppIcon 16.",
    web: `<div style="display:grid;justify-items:start;gap:8px"><div class="g-node is-app" style="position:relative;--app:var(--tb-app-knowledge)"><div class="band" data-m="appchip appchip-name"><i class="tb-app-icon s32" style="background-image:${APP_STILL_WEB}" aria-hidden="true"></i><span><h3>Knowledge</h3><small>Memory</small></span></div></div><i class="tb-app-icon s16" data-m="appchip-icon" style="background-image:${APP_STILL_WEB}" aria-hidden="true"></i></div>`,
    chat: `<div style="display:grid;justify-items:start;gap:8px"><span class="tbd-app-chip" data-m="appchip appchip-name" style="background:var(--tb-app-knowledge)"><span class="tb-app-icon s16" style="background-image:${APP_STILL_CHAT}" aria-hidden="true"></span>Knowledge</span><span class="tb-app-icon s16" data-m="appchip-icon" style="background-image:${APP_STILL_CHAT}" aria-hidden="true"></span></div>`,
  },
];

const BAND_WHY = "Web has no app chip. The reference is the canvas app header band (icon 32, name 17/900, group line), a larger 3-part header, so size, padding and type are not comparable.";

export const PROBES: ProbeSpec[] = [
  { id: "button-primary", cell: "button", label: "Primary button", props: CONTROL },
  { id: "button-secondary", cell: "button", label: "Secondary button", props: CONTROL },
  { id: "field-label", cell: "field", label: "Field label", props: TEXT },
  { id: "field-input", cell: "field", label: "Text input", props: [...CONTROL, "width"] },
  { id: "select-label", cell: "select", label: "Select label", props: TEXT },
  { id: "select-trigger", cell: "select", label: "Select trigger (closed)", props: [...CONTROL, "width"] },
  { id: "card", cell: "card", label: "Card", props: ["padL", "padR", "padT", "padB", "radius", "bg", "edgeColor", "edgeWidth"] },
  { id: "tag-live", cell: "tag", label: "Tag, live", props: CONTROL },
  { id: "tag-needs-you", cell: "tag", label: "Tag, needs you", props: CONTROL },
  { id: "tab-current", cell: "tabs", label: "Tab, current", props: CONTROL },
  { id: "tab-idle", cell: "tabs", label: "Tab, idle", props: CONTROL },
  { id: "stepflow", cell: "stepflow", label: "StepFlow frame", props: ["width", "height", "radius", "bg"], na: { native: { props: ["radius"], why: "TBDStepFlow draws no corner: the host sheet clips it (the proof cell clips it with TBDBrickShape, as the component sheet does)." } } },
  { id: "stepflow-step-done", cell: "stepflow", label: "Step row, done step", props: TEXT },
  { id: "stepflow-step-current", cell: "stepflow", label: "Step row, current step", props: TEXT },
  { id: "stepflow-step-upcoming", cell: "stepflow", label: "Step row, next step", props: TEXT },
  { id: "stepflow-body", cell: "stepflow", label: "Step body", props: ["padL", "padR"] },
  { id: "stepflow-foot", cell: "stepflow", label: "Foot", props: ["padL", "padR", "padT", "padB", "edgeColor", "edgeWidth"] },
  { id: "stepflow-prev", cell: "stepflow", label: "Previous (secondary)", props: ["height", "bg", "color", "edgeColor", "edgeWidth"] },
  { id: "stepflow-next", cell: "stepflow", label: "Next (primary)", props: ["height", "bg", "color"] },
  { id: "notice-live", cell: "notice", label: "Notice, live", props: [...CONTROL, "padT", "padB"], missing: { chat: "Chat renders no live notice. Nearest: .modal__banner (neutral grey)." } },
  { id: "notice-needs-you", cell: "notice", label: "Notice, needs you", props: [...CONTROL, "padT", "padB"] },
  { id: "agent-card", cell: "agentcard", label: "Agent card", props: ["width", "height", "padT", "padR", "padB", "padL", "radius", "bg", "edgeColor", "edgeWidth"] },
  { id: "agent-avatar", cell: "agentcard", label: "Agent avatar", props: ["width", "height", "fontFamily", "fontSize", "fontWeight", "radius", "bg", "color"] },
  { id: "agent-name", cell: "agentcard", label: "Agent name", props: TEXT },
  { id: "agent-meta", cell: "agentcard", label: "Harness line", props: TEXT },
  { id: "appchip", cell: "appchip", label: "App chip (web: header band)", props: ["height", "padL", "padR", "radius", "bg", "color", "edgeColor"], na: { web: { props: ["height", "padL", "padR"], why: BAND_WHY } } },
  { id: "appchip-name", cell: "appchip", label: "App name", props: TEXT, na: { web: { props: ["fontSize", "fontWeight"], why: BAND_WHY } } },
  { id: "appchip-icon", cell: "appchip", label: "AppIcon 16", props: ["width", "height", "radius", "bg", "edgeColor", "edgeWidth"] },
];

/** Page CSS of the web column that is not in components.css: canvas cards, copied from mockups/build-workspace.ts STYLE. */
export const WEB_CANVAS_CSS = `
.g-node { position: absolute; box-sizing: border-box; display: grid; border-radius: var(--tb-radius-brick); background: var(--tb-tile); color: var(--tb-ink); box-shadow: var(--tb-ring-strong); }
.g-node.is-agent { width: 208px; padding: 10px 14px 12px 12px; gap: 8px; }
.g-node.is-agent .row { display: flex; align-items: center; gap: 10px; min-width: 0; }
.g-node.is-agent .avatar { flex: none; display: inline-grid; place-items: center; width: 32px; height: 32px; border-radius: var(--tb-radius-brick); background: var(--tb-primary-fill); color: var(--tb-primary-on); font-weight: var(--tb-weight-head); font-size: var(--tb-text-control); line-height: 1; }
.g-node.is-agent h3 { font-size: 1rem; font-weight: var(--tb-weight-head); line-height: 20px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.g-node.is-agent .meta { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 6px; font-size: var(--tb-text-hint); line-height: 16px; color: var(--tb-muted); font-weight: var(--tb-weight-nav); }
.g-node.is-app { width: 264px; overflow: visible; }
.g-node.is-app .band { display: flex; align-items: center; gap: 10px; padding: 10px 12px; border-radius: var(--tb-radius-brick) var(--tb-radius-brick) 0 0; background: var(--app); color: var(--tb-app-on); }
.g-node.is-app .band h3 { font-size: 1.0625rem; font-weight: var(--tb-weight-head); line-height: 20px; color: var(--tb-app-on); }
.g-node.is-app .band small { display: block; font-size: var(--tb-text-hint); font-weight: var(--tb-weight-nav); line-height: 16px; color: var(--tb-app-on); }
.g-node.is-app .band .tb-app-icon { box-shadow: 0 0 0 2px var(--tb-app-on); }
`;
