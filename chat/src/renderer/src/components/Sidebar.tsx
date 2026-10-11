import { type ReactNode, useEffect, useState } from "react";
import { createPortal } from "react-dom";
import type { Agent, Block } from "@shared/types";
import { useStore } from "@/lib/store";
import { workspaceFooterLabel } from "@/lib/workspaceLabel";
import { Avatar, Icon, timeLabel } from "./primitives";

function useRailTooltip(name: string): { events: { onMouseEnter: (event: React.MouseEvent<HTMLDivElement>) => void; onMouseLeave: () => void; onFocus: (event: React.FocusEvent<HTMLDivElement>) => void; onBlur: () => void }; label: ReactNode } {
  const [top, setTop] = useState<number | null>(null);
  const show = (event: React.MouseEvent<HTMLDivElement> | React.FocusEvent<HTMLDivElement>): void => {
    const rect = event.currentTarget.getBoundingClientRect();
    setTop(Math.min(window.innerHeight - 52, Math.max(8, rect.top + 12)));
  };
  return {
    events: { onMouseEnter: show, onMouseLeave: () => setTop(null), onFocus: show, onBlur: () => setTop(null) },
    label: top === null ? null : createPortal(<div className="rail-name-rollout" role="tooltip" style={{ top }}>{name}</div>, document.body),
  };
}

/** The right-click menu is about one agent row. */
type MenuState = { x: number; y: number; agent: Agent };

function ContextMenu({
  state,
  onClose,
}: {
  state: MenuState;
  onClose(): void;
}): ReactNode {
  const { patchAgent, setPanel, select } = useStore();
  const { agent } = state;

  useEffect(() => {
    const dismiss = (): void => onClose();
    window.addEventListener("click", dismiss);
    window.addEventListener("contextmenu", dismiss);
    return () => {
      window.removeEventListener("click", dismiss);
      window.removeEventListener("contextmenu", dismiss);
    };
  }, [onClose]);

  const item = (icon: string, label: string, action: () => void, danger = false): ReactNode => (
    <button
      className={`menu__item${danger ? " menu__item--danger" : ""}`}
      onClick={() => {
        action();
        onClose();
      }}
    >
      <Icon name={icon} />
      {label}
    </button>
  );

  // Keep the menu on screen when the click lands near the bottom edge.
  const top = Math.min(state.y, window.innerHeight - 330);

  return (
    <div className="menu" style={{ left: state.x, top }} onClick={(e) => e.stopPropagation()}>
      {item("pin", agent.pinned ? "Unpin" : "Pin", () => patchAgent(agent.id, { pinned: !agent.pinned }))}
      {item("bell", agent.unread ? "Mark as Read" : "Mark as Unread", () =>
        patchAgent(agent.id, { unread: !agent.unread }),
      )}
      <div className="menu__sep" />
      {item("pencil", "Edit Profile", () => {
        select(agent.id);
        setPanel("settings");
      })}
      <div className="menu__sep" />
      {item("copy", "Copy conversation ID", () => {
        void navigator.clipboard.writeText(agent.id);
      })}
      <div className="menu__sep" />
      {item("eyeOff", "Hide from sidebar", () => patchAgent(agent.id, { hidden: true }))}
    </div>
  );
}

/**
 * The preview is DERIVED from the transcript, not stored on the agent.
 *
 * The agent list is rebuilt from the control plane on every launch, so anything
 * kept on those objects is lost while the conversation that persisted sits
 * right there — every row read "No messages yet" above a chat full of messages.
 * One source of truth: the messages.
 */
function lastOf(blocks: Block[] | undefined): { text: string; at: number } | null {
  if (!blocks?.length) return null;
  for (let i = blocks.length - 1; i >= 0; i--) {
    const b = blocks[i];
    if (b?.kind === "text" && b.text.trim()) {
      return { text: b.text.replace(/\s+/g, " ").trim(), at: b.at };
    }
  }
  return null;
}

function Row({
  agent,
  onMenu,
}: {
  agent: Agent;
  onMenu(state: MenuState): void;
}): ReactNode {
  const { activeAgentId, select } = useStore();
  const tooltip = useRailTooltip(agent.name);
  const active = agent.id === activeAgentId;

  return (
    <div
      {...tooltip.events}
      role="button" tabIndex={0} aria-label={agent.name}
      onKeyDown={(e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); select(agent.id); } }}
      className={`row row--agent${active ? " row--active" : ""}`}
      onClick={() => select(agent.id)}
      onContextMenu={(e) => {
        e.preventDefault();
        e.stopPropagation();
        select(agent.id);
        onMenu({ x: e.clientX, y: e.clientY, agent });
      }}
    >
      {tooltip.label}
      <Avatar name={agent.name} accent={agent.accent} src={agent.avatar} size={37} />
      {agent.status === "offline" ? <span className="rail-agent-status" title="Not answering" aria-label="Not answering">○</span> : null}
      {agent.unread ? <span className="row__unread rail-agent-unread" aria-label="Unread messages" /> : null}
      {agent.pinned ? <span className="rail-agent-pin" aria-label="Pinned"><Icon name="pin" size={10} /></span> : null}
    </div>
  );
}

/**
 * Owner approvals waiting in the workspace's apps (counts only, C24). TBD is
 * the default place to notice them; the hold pages open in the browser (B4).
 */
function PendingHolds(): ReactNode {
  const issuer = useStore((s) => s.issuer);
  const [holds, setHolds] = useState<{ product: string; count: number }[]>([]);
  useEffect(() => {
    let alive = true;
    const load = (): void => { void window.studio?.pendingHolds().then((h) => { if (alive) setHolds(h); }).catch(() => {}); };
    load();
    const timer = window.setInterval(load, 60_000);
    return () => { alive = false; window.clearInterval(timer); };
  }, []);
  const total = holds.reduce((n, h) => n + h.count, 0);
  if (total === 0) return null;
  const origin = issuer.startsWith("http") ? issuer : `https://${issuer}`;
  return (
    <button className="foot-row" title={holds.map((h) => `${h.product}: ${h.count}`).join(", ")} onClick={() => void window.studio.openExternal(origin)}>
      <Icon name="bell" />
      <span className="foot-row__label">{total === 1 ? "1 approval waiting" : `${total} approvals waiting`}</span>
    </button>
  );
}

export function Sidebar(): ReactNode {
  const { agents, setPaletteOpen, account, signOut, refreshAgents, issuer, patchAgent, authError } =
    useStore();
  const [menu, setMenu] = useState<MenuState | null>(null);
  const [accountMenu, setAccountMenu] = useState(false);
  const workspaceName = useStore((s) => workspaceFooterLabel(s.portalWorkspaces, s.portalWorkspaceId));

  // Hiding is reversible, so the count has to be visible somewhere.
  const hiddenCount = agents.filter((a) => a.hidden).length;
  // Searching moved to the palette; the inline filter this replaced ran on a
  // query nothing could ever set, so it matched everything and then told the
  // person nothing matched "".
  const visible = agents.filter((a) => !a.hidden);

  // Most recently active first, from the transcripts themselves.
  const recency = (a: Agent): number => lastOf(useStore.getState().conversations[a.id])?.at ?? 0;
  const byRecent = [...visible].sort((x, y) => recency(y) - recency(x));
  const pinned = byRecent.filter((a) => a.pinned);
  const rest = byRecent.filter((a) => !a.pinned);

  return (
    <aside className="sidebar">
      <div className="tb-sidebar-brand"><img src="./brand/teal-brick-colour.png" alt="" /> <span>Teal Brick</span></div>
      <div className="sidebar__search">
        <button className="search search--button" onClick={() => setPaletteOpen(true)}>
          <Icon name="search" size={14} />
          <span className="search__placeholder">Search</span>
          <span className="kbd">⌘K</span>
        </button>
      </div>

      <div className="sidebar__list">
        {pinned.length > 0 ? (
          <>
            <div className="section-head">Pinned</div>
            {pinned.map((a) => (
              <Row key={a.id} agent={a} onMenu={setMenu} />
            ))}
            {rest.length > 0 ? <div className="section-head">Agents</div> : null}
          </>
        ) : null}
        {rest.map((a) => (
          <Row key={a.id} agent={a} onMenu={setMenu} />
        ))}
        {visible.length === 0 ? (
          <div className="empty">
            {hiddenCount > 0
              ? "Every agent is hidden. Show them from the account menu."
              : /* Written by refreshAgents for exactly this case — a signed-in
                   person with no grants — and previously read by nobody, so the
                   app just sat empty with no explanation. */
                (authError ?? "No agents yet.")}
          </div>
        ) : null}
      </div>

      <div className="sidebar__foot">
        <PendingHolds />
        <button className="foot-row account-rail-button" title="Account and workspace" aria-label="Account and workspace" onClick={() => setAccountMenu((v) => !v)}>
          <Avatar name={account?.email ?? "?"} accent="#1b3a34" size={28} />
        </button>

        {accountMenu ? (
          <div className="account-menu">
            <div className="account-menu__identity">{account?.email ?? "Not signed in"}<small>{workspaceName}</small></div>
        <label className="workspace-switcher">Workspace
          <select aria-label="Workspace" value={useStore.getState().portalWorkspaceId ?? ''} onChange={e => void useStore.getState().switchPortalWorkspace(e.target.value)}>
            {useStore.getState().portalWorkspaces.map(w => <option key={w.id} value={w.id}>{w.name}</option>)}
          </select>
        </label>
        <button className="menu__item" onClick={() => { setAccountMenu(false); void useStore.getState().loadPortalWorkspaces(); }}>Refresh workspaces</button>
            <div className="menu__sep" />
            <button
              className="menu__item"
              onClick={() => {
                setAccountMenu(false);
                void refreshAgents({ refreshSession: true });
              }}
            >
              <Icon name="download" /> Refresh agents
            </button>
            {hiddenCount > 0 ? (
              <button
                className="menu__item"
                onClick={() => {
                  setAccountMenu(false);
                  for (const a of agents.filter((x) => x.hidden)) patchAgent(a.id, { hidden: false });
                }}
              >
                <Icon name="eye" /> Show {hiddenCount} hidden agent{hiddenCount === 1 ? "" : "s"}
              </button>
            ) : null}
            <div className="menu__sep" />
            <button
              className="menu__item menu__item--danger"
              onClick={() => {
                setAccountMenu(false);
                void signOut();
              }}
            >
              <Icon name="close" /> Sign out
            </button>
            <div className="account-menu__issuer">{issuer}</div>
          </div>
        ) : null}
      </div>

      {menu ? <ContextMenu state={menu} onClose={() => setMenu(null)} /> : null}
    </aside>
  );
}
