import type { ReactNode } from "react";
import { isImage, toAvatarDataUrl } from "../lib/avatarImage";
import { harnessLabel } from "../lib/agentInfo";
import { useEffect, useState, useRef } from "react";
import {
  DEFAULT_SPEC,
  FREQUENCIES,
  type ScheduleSpec,
  WEEKDAYS,
  describeCron,
  timeOptions,
  toCron,
} from "@/lib/schedule";
import { useStore, type PanelView } from "@/lib/store";
import type { LocalAction, LocalPermission } from "@shared/ipc";
import { Avatar, Icon, Toggle } from "./primitives";

/**
 * The agent panel: everything about THIS agent that is not the conversation.
 *
 * Every section here is read from the agent's own /eve/v1/info — its real
 * schedules, connections, channels, skills, tools, and subagents. Nothing is
 * seeded. Where the agent reports nothing, the panel says so; where we have not
 * asked yet, it says that instead. Those are different states and showing one
 * as the other is how a console starts lying to its operator.
 *
 * Editing is deliberately absent: eve exposes this information read-only, and a
 * Save button with nowhere to POST would be worse than no button.
 */

/**
 * Never throws.
 *
 * `new URL()` rejects anything that is not an absolute URL, and a control-plane
 * record can legitimately hold a bare host or a daemon endpoint. A panel must
 * not be able to take the whole renderer down because an agent was registered
 * with an odd URL — showing the raw value is a fine answer; a white window is
 * not.
 */
function hostOf(url?: string): string {
  if (!url) return "—";
  try {
    return new URL(url).host;
  } catch {
    return url;
  }
}

function Head({
  title,
  onBack,
  onClose,
}: {
  title: string;
  onBack?: () => void;
  onClose(): void;
}): ReactNode {
  return (
    <div className="panel__head">
      {onBack ? (
        <button className="topbar__btn" onClick={onBack} style={{ WebkitAppRegion: "no-drag" } as never}>
          <Icon name="chevronLeft" />
        </button>
      ) : (
        <span style={{ width: 28 }} />
      )}
      <span className="panel__title">{title}</span>
      <button className="topbar__btn" onClick={onClose} style={{ WebkitAppRegion: "no-drag" } as never}>
        <Icon name="close" />
      </button>
    </div>
  );
}

function Section({
  title,
  count,
  children,
}: {
  title: string;
  count?: number;
  children: ReactNode;
}): ReactNode {
  return (
    <>
      <div className="panel__section-head" style={{ marginTop: 20 }}>
        <span className="panel__section-title">{title}</span>
        {count != null ? <span className="muted">{count}</span> : null}
      </div>
      {children}
    </>
  );
}

function Row({
  icon,
  title,
  detail,
  onClick,
}: {
  icon: ReactNode;
  title: string;
  detail?: string;
  onClick?: () => void;
}): ReactNode {
  const body = (
    <>
      <span className="routine-row__dot">{icon}</span>
      <span style={{ flex: 1, minWidth: 0 }}>
        <div className="routine-row__name">{title}</div>
        {detail ? <div className="routine-row__when">{detail}</div> : null}
      </span>
    </>
  );
  return onClick ? (
    <button className="routine-row" onClick={onClick}>
      {body}
    </button>
  ) : (
    <div className="routine-row">{body}</div>
  );
}

/** Distinguishes "not asked yet" from "the agent has none". */
function Empty({ loaded, none }: { loaded: boolean; none: string }): ReactNode {
  return <div className="muted" style={{ padding: "2px 8px 6px" }}>{loaded ? none : "Loading…"}</div>;
}

function Overview(): ReactNode {
  const { agents, activeAgentId, details, models, setPanel, openRoutine, infoError, loadAgentInfo } = useStore();
  useEffect(() => { void loadAgentInfo(activeAgentId); const timer=setInterval(()=>void loadAgentInfo(activeAgentId),15000);return ()=>clearInterval(timer); }, [activeAgentId, loadAgentInfo]);
  const agent = agents.find((a) => a.id === activeAgentId);
  const info = details[activeAgentId];
  const loaded = Boolean(info);
  if (!agent) return null;

  const schedules = info?.schedules ?? [];
  const channels = info?.channels ?? [];
  const subagents = info?.subagents ?? [];
  // From the control plane, not from the agent's own /info: an agent listing
  // its own permissions would be the agent grading its own homework.
  const peers = agent.peers ?? [];

  return (
    <>
      <Head title="Agent" onClose={() => setPanel("none")} />
      <div className="panel__body">
        <div className="agent-inspector__identity">
          <span className="workspace-home__eyebrow">WORKSPACE AGENT</span>
          <h2>{agent.name}</h2>
        </div>
        <dl className="agent-inspector__metadata">
          <div><dt>Host</dt><dd>{agent.url ? hostOf(agent.url) : "No endpoint configured"}</dd></div>
          <div><dt>Model</dt><dd>{models[activeAgentId] ?? "Not reported"}</dd></div>
          {info?.harness && <div><dt>Harness</dt><dd>{harnessLabel(info)}</dd></div>}
        </dl>

        {infoError && <div role="alert" className="card">{infoError} <button className="btn" onClick={()=>void loadAgentInfo(activeAgentId)}>Retry</button></div>}
        {info?.native ? <Section title="Native capabilities">
          <p>{info.capabilities?.join(" · ")}</p>
          <p className="muted">Conversations resume the same native {harnessLabel(info)} session. Eve routines and host restart controls do not apply to this harness.</p>
        </Section> : <Section title="Routines" count={loaded ? schedules.length : undefined}>
          {schedules.length === 0 ? (
            infoError ? null : <Empty loaded={loaded} none="This agent runs nothing on a schedule." />
          ) : (
            schedules.map((s) => (
              <Row
                key={s.name}
                icon={<Icon name="clock" size={14} />}
                title={s.name}
                detail={`${s.enabled === false ? "Paused · " : ""}${describeCron(s.cron)}`}
                onClick={() => openRoutine(s.name)}
              />
            ))
          )}
        </Section>

        }
        <Section title="Channels" count={loaded ? channels.length : undefined}>
          {channels.length === 0 ? (
            infoError ? null : <Empty loaded={loaded} none="Reachable only through this app." />
          ) : (
            channels.map((c) => (
              <Row
                key={c.name + (c.urlPath ?? "")}
                icon={<Icon name="monitor" size={14} />}
                title={c.name}
                detail={c.urlPath}
              />
            ))
          )}
        </Section>

        {/*
          Who this agent may call, straight from the control plane.

          Read-only on purpose. Granting an edge is a governance decision and it
          belongs in the admin, next to who may talk to the agent at all — a
          desktop app that could quietly widen an agent's reach would make the
          admin a place you consult rather than the place that decides. Showing
          it here still matters: when a delegation fails, the first question is
          whether the edge exists, and the answer should not require a browser.
        */}
        {peers.length > 0 ? (
          <Section title="Peers" count={peers.length}>
            {peers.map((p) => {
              const known = agents.find((a) => a.id === p.id || a.name === p.name);
              return (
                <Row
                  key={p.id}
                  icon={<Avatar name={p.name} accent={known?.accent ?? "#7c6cf0"} size={16} />}
                  title={p.name}
                  detail={p.purpose ?? "granted"}
                />
              );
            })}
          </Section>
        ) : null}

        {subagents.length > 0 ? (
          <Section title="Subagents" count={subagents.length}>
            {subagents.map((s) => (
              <Row
                key={s.name}
                icon={<Icon name="package" size={14} />}
                title={s.name}
                detail={s.description}
              />
            ))}
          </Section>
        ) : null}

        <div style={{ marginTop: 20, display: "flex", gap: 8 }}>
          <button className="btn" style={{ flex: 1 }} onClick={() => setPanel("settings")}>
            Settings
          </button>
        </div>
      </div>
    </>
  );
}

/** A routine, with what it does and a way to stop it. */
function RoutineView(): ReactNode {
  const { details, activeAgentId, activeRoutineId, setPanel } = useStore();
  useEffect(()=>{const timer=setInterval(()=>void useStore.getState().loadAgentInfo(activeAgentId),15000);return ()=>clearInterval(timer);},[activeAgentId]);
  const schedule = (details[activeAgentId]?.schedules ?? []).find((s) => s.name === activeRoutineId);
  if (!schedule) return null;

  return (
    <>
      <Head title="Routine" onBack={() => setPanel("overview")} onClose={() => setPanel("none")} />
      <div className="panel__body">
        <div className="field">
          <div className="field__label">Name</div>
          <div className="card">{schedule.name}</div>
        </div>

        <div className="field">
          <div className="field__label">What it does</div>
          <div className="card" style={{ whiteSpace: "pre-wrap" }}>
            {schedule.markdown?.trim() ? (
              schedule.markdown
            ) : (
              // Distinguish 'no instruction' from 'eve did not report one'.
              // Schedules authored as source may keep their prompt in a form the
              // info route does not surface, and saying nothing at all reads as
              // an empty routine.
              <span className="muted">
                The agent does not report an instruction for this routine. It is defined in{" "}
                <span style={{ fontFamily: "var(--font-mono)" }}>
                  the agent’s authored or extension schedule source
                </span>
                .
              </span>
            )}
          </div>
        </div>

        <div className="field">
          <div className="field__label">When it runs</div>
          <div className="card">
            {describeCron(schedule.cron)}
            <div className="muted" style={{ fontFamily: "var(--font-mono)", marginTop: 4 }}>
              {schedule.cron ?? "—"}
            </div>
          </div>
        </div>

        <div className="field">
          <div className="field__label">Status</div>
          <div className="card">{schedule.dynamic ? `${schedule.enabled===false?"Paused":"Active"} · revision ${schedule.revision}. ${schedule.lastRun ? `Last run: ${schedule.lastRun.status} at ${new Date(schedule.lastRun.updatedAt).toLocaleString()}` : "No runs yet."}${schedule.enabled!==false&&schedule.nextRunAt ? ` Next: ${new Date(schedule.nextRunAt).toLocaleString()}`:""}` : "Execution history is not reported by this agent."}</div>
        </div>

        <div className="muted" style={{ marginTop: 12 }}>
          Routines are managed where they live: ask the agent, or change them in its harness.
        </div>
      </div>
    </>
  );
}

function Settings(): ReactNode {
  const { agents, activeAgentId, patchAgent, setPanel, details, models, resetConversation, sessions } =
    useStore();
  const agent = agents.find((a) => a.id === activeAgentId);
  const info = details[activeAgentId];
  const avatarInputRef = useRef<HTMLInputElement>(null);
  const [avatarError, setAvatarError] = useState<string | null>(null);
  if (!agent) return null;

  return (
    <>
      <Head title="Settings" onBack={() => setPanel("overview")} onClose={() => setPanel("none")} />
      <div className="panel__body">
        <div className="agent-portrait">
          <Avatar name={agent.name} accent={agent.accent} src={agent.avatar} size={62} />
          <input
            ref={avatarInputRef}
            type="file"
            accept="image/*"
            style={{ display: "none" }}
            onChange={async (e) => {
              const file = e.target.files?.[0];
              // Cleared immediately so choosing the same file twice still fires.
              e.target.value = "";
              if (!file) return;
              if (!isImage(file)) {
                setAvatarError("That file is not an image.");
                return;
              }
              try {
                const dataUrl = await toAvatarDataUrl(file);
                patchAgent(agent.id, { avatar: dataUrl });
                setAvatarError(null);
              } catch (error) {
                setAvatarError((error as Error).message);
              }
            }}
          />
          <div className="agent-portrait__actions">
            <button className="btn btn--small" onClick={() => avatarInputRef.current?.click()}>
              {agent.avatar ? "Change picture" : "Upload picture"}
            </button>
            {agent.avatar ? (
              <button
                className="btn btn--small"
                // Back to the lettered mark rather than to nothing: an agent
                // always has an avatar, and this only chooses which kind.
                onClick={() => patchAgent(agent.id, { avatar: undefined })}
              >
                Remove
              </button>
            ) : null}
          </div>
          {avatarError ? <div className="agent-portrait__error">{avatarError}</div> : null}
        </div>

        <div className="field">
          <div className="field__label">Display name</div>
          <input
            className="input"
            value={agent.name}
            onChange={(e) => patchAgent(agent.id, { name: e.target.value })}
          />
        </div>



        <div className="card stack-row">
          <div style={{ flex: 1 }}>
            <div>Start a fresh conversation</div>
            <div className="muted">
              {sessions[activeAgentId]
                ? "Retires the agent's current session. Use this if replies stopped arriving — an agent that restarted mid-turn leaves a session that can never finish."
                : "No session yet; the next message starts one."}
            </div>
          </div>
          <button
            className="btn"
            disabled={!sessions[activeAgentId]}
            onClick={() => resetConversation(activeAgentId)}
          >
            Reset
          </button>
        </div>

        <div className="card stack-row">
          <div style={{ flex: 1 }}>
            <div>Notifications</div>
            <div className="muted">When it needs your answer, or finishes while you are elsewhere.</div>
          </div>
          <Toggle
            on={agent.notifications ?? false}
            onChange={(on) => patchAgent(agent.id, { notifications: on })}
          />
        </div>


        <div className="field" style={{ marginTop: 18 }}>
          <div className="field__label">Reported by the agent</div>
          <div className="card">
            <div className="stack-row" style={{ marginBottom: 6 }}>
              <span style={{ flex: 1 }} className="muted">Name</span>
              <span style={{ fontSize: 12.5 }}>{info?.name ?? "—"}</span>
            </div>
            <div className="stack-row" style={{ marginBottom: 6 }}>
              <span style={{ flex: 1 }} className="muted">Model</span>
              <span style={{ fontSize: 12.5, fontFamily: "var(--font-mono)" }}>
                {models[activeAgentId] ?? "—"}
              </span>
            </div>
            <div className="stack-row">
              <span style={{ flex: 1 }} className="muted">Host</span>
              <span style={{ fontSize: 12.5 }}>{hostOf(agent.url)}</span>
            </div>
          </div>
        </div>

        <div className="muted" style={{ marginTop: 14 }}>
          An agent&apos;s identity, instructions, and capabilities live in its own repository. This
          panel reports them; it does not change them.
        </div>
      </div>
    </>
  );
}

export function Panel(): ReactNode {
  const panel = useStore((s) => s.panel);
  /**
   * The view being shown, which lags the store while the drawer closes.
   *
   * A component that unmounts cannot animate: the moment `panel` becomes
   * "none" the element is gone, and any exit animation is attached to
   * something that no longer exists. So the last real view is held for the
   * length of the animation, and only then released.
   */
  const [shown, setShown] = useState<PanelView>(panel);
  const [closing, setClosing] = useState(false);

  useEffect(() => {
    if (panel !== "none") {
      setClosing(false);
      setShown(panel);
      return;
    }
    if (shown === "none") return;
    setClosing(true);
    const timer = setTimeout(() => {
      setClosing(false);
      setShown("none");
    }, 150);
    return () => clearTimeout(timer);
  }, [panel, shown]);

  if (shown === "none") return null;
  return (
    <aside className={`panel${closing ? " panel--closing" : ""}`}>
      {/* Gated on `shown`, not `panel`: `panel` is already "none" while the
          drawer animates out, so gating on it blanked the contents instantly
          and slid an empty box off screen — defeating the very hold above. */}
      {shown === "overview" ? <Overview /> : null}
      {shown === "routine" ? <RoutineView /> : null}
      {shown === "settings" ? <Settings /> : null}
    </aside>
  );
}
