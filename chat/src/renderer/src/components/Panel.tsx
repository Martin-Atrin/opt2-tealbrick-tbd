import type { ReactNode } from "react";
import { CodexAccess } from './CodexAccess';
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
/**
 * True when the renderer is running inside TBD's native WKWebView host
 * rather than the standalone Electron build. `window.tbdAudio` is only
 * injected by the TBD bridge (see `src/tbd/browser.ts`) — the same signal
 * `lib/dictation.ts` uses to pick the native audio path.
 *
 * The Live voice agent transport (`src/tbd/voice.ts`) always throws in the
 * TBD build ("Live voice agent transport is not connected."), so the voice
 * picker below is hidden there; the standalone build still has a working
 * Live API session and keeps the picker.
 */
function hasLiveVoiceTransport(): boolean {
  return typeof (window as unknown as { tbdAudio?: unknown }).tbdAudio === "undefined";
}

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

/** Capability comes from the authenticated management channel, never the URL. */
function RoutineWake({ name, value = false, onChange }: { name?: string; value?: boolean; onChange?: (enabled: boolean) => void }): ReactNode {
  const { activeAgentId, agents, portalWorkspaceId, details } = useStore();
  const url = agents.find(a => a.id === activeAgentId)?.url;
  const agentId = activeAgentId;
  const [status, setStatus] = useState<{ supported?: boolean; reason?: string; routines?: string[]; pending?: boolean; managed?: string[] }>();
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  useEffect(() => {
    let cancelled = false;
    if (url && window.studio) void window.studio.manage({ agentId, path: "/tealbrick/management" }).then(res => {
      if (!cancelled) setStatus(res.ok ? (res.data as { wake?: typeof status })?.wake ?? { reason: "Host wake is not configured." } : { reason: "Host wake is unavailable on this agent." });
    }).catch(() => { if (!cancelled) setStatus({ reason: "Could not check host wake support." }); });
    return () => { cancelled = true; };
  }, [url, portalWorkspaceId]);
  const sharedRoutine = details[activeAgentId]?.schedules.find(s => s.name === name && s.dynamic);
  const checked = sharedRoutine ? Boolean(sharedRoutine.wake) : name ? Boolean(status?.routines?.includes(name)) : value;
  const change = async (enabled: boolean): Promise<void> => {
    if (onChange) { onChange(enabled); return; }
    if (!url || !name) return;
    const dynamic=useStore.getState().details[activeAgentId]?.schedules.find(s=>s.name===name);
    if(dynamic?.dynamic){const ok=await useStore.getState().updateSchedule(activeAgentId,name,{wake:enabled});if(ok)setStatus(s=>({...s,routines:[...(s?.routines??[]).filter(n=>n!==name),...(enabled?[name]:[])]}));return;}
    setBusy(true); setMessage("");
    const current = (): boolean => useStore.getState().activeAgentId === activeAgentId && useStore.getState().portalWorkspaceId === portalWorkspaceId;
    try {
      const res = await window.studio.manage({ agentId, path: "/tealbrick/management", body: { operation: "wake", name, wake: enabled, requestId: crypto.randomUUID() } });
      if (!current()) return;
      const data = res.data as { ok?: boolean; error?: string };
      if (res.ok && data?.ok) {
        setStatus(s => ({ ...s, pending: false, routines: [...(s?.routines ?? []).filter(n => n !== name), ...(enabled ? [name] : [])] }));
        setMessage(enabled ? "Host wake enabled. Eve runs the routine on its normal schedule." : "Host wake disabled. Eve keeps its normal schedule.");
      } else setMessage(`Host wake could not be updated (${data?.error ?? res.status}). Check host registration before retrying.`);
    } catch { if (current()) setMessage("The response was interrupted. Check host registration before retrying."); }
    finally { if (current()) setBusy(false); }
  };
  return <div className="field" style={{ marginBottom: 12 }}>
    <label><input type="checkbox" checked={checked} disabled={busy || !status?.supported || Boolean(name && !status.managed?.includes(name))} onChange={e => void change(e.target.checked)} /> Wake agent for this routine</label>
    <div className="muted">{message || (status?.pending ? "Host wake changes are pending. Ask your administrator to reconcile them." : name && status?.supported && !status.managed?.includes(name) ? "Wake settings are available for routines created through Teal Brick management." : status?.supported ? "Optional · UTC schedules. Requires host wake permission; Eve still runs the routine." : status?.reason ?? "Checking host wake support…")}</div>
  </div>;
}

/** Create a routine that is actually written into the agent's repository. */
function NewRoutine(): ReactNode {
  const { activeAgentId, createSchedule, manageError } = useStore();
  const [open, setOpen] = useState(false);
  const [wake, setWake] = useState(false);
  const [name, setName] = useState("");
  const [instruction, setInstruction] = useState("");
  const [spec, setSpec] = useState<ScheduleSpec>(DEFAULT_SPEC);
  const [busy, setBusy] = useState(false);

  if (!open) {
    return (
      <button className="btn" style={{ width: "100%", marginBottom: 8 }} onClick={() => setOpen(true)}>
        New routine
      </button>
    );
  }

  const cron = toCron(spec);
  const set = (patch: Partial<ScheduleSpec>): void => setSpec({ ...spec, ...patch });
  const needsTime = ["daily", "weekdays", "weekly", "monthly"].includes(spec.frequency);

  const submit = async (): Promise<void> => {
    if (!name.trim() || !instruction.trim() || !cron) return;
    setBusy(true);
    const ok = await createSchedule(activeAgentId, {
      name: name.trim(),
      cron,
      instruction: instruction.trim(),
      wake,
    });
    setBusy(false);
    if (ok) {
      setOpen(false);
      setName("");
      setInstruction("");
      setWake(false);
    }
  };

  return (
    <div className="card" style={{ marginBottom: 10 }}>
      <div className="field" style={{ marginBottom: 10 }}>
        <div className="field__label">Name</div>
        <input
          className="input"
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="Morning digest"
        />
      </div>

      <div className="field" style={{ marginBottom: 10 }}>
        <div className="field__label">What should it do each time it runs?</div>
        <textarea
          className="textarea"
          value={instruction}
          onChange={(e) => setInstruction(e.target.value)}
          placeholder="Skim my inbox and calendar and send me one short update."
        />
      </div>

      <div className="field" style={{ marginBottom: 8 }}>
        <div className="field__label">When to run</div>
        <div className="sched">
          <select
            className="input sched__freq"
            value={spec.frequency}
            onChange={(e) => set({ frequency: e.target.value as ScheduleSpec["frequency"] })}
          >
            {FREQUENCIES.map((f) => (
              <option key={f.value} value={f.value}>
                {f.label}
              </option>
            ))}
          </select>

          {spec.frequency === "hourly" ? (
            <select
              className="input"
              value={spec.minute}
              onChange={(e) => set({ minute: Number(e.target.value) })}
            >
              {[0, 15, 30, 45].map((m) => (
                <option key={m} value={m}>
                  at :{String(m).padStart(2, "0")}
                </option>
              ))}
            </select>
          ) : null}

          {spec.frequency === "weekly" ? (
            <select
              className="input"
              value={spec.weekday}
              onChange={(e) => set({ weekday: Number(e.target.value) })}
            >
              {WEEKDAYS.map((d, i) => (
                <option key={d} value={i}>
                  {d}
                </option>
              ))}
            </select>
          ) : null}

          {spec.frequency === "monthly" ? (
            <select
              className="input"
              value={spec.day}
              onChange={(e) => set({ day: Number(e.target.value) })}
            >
              {/* 28 days, so the routine exists in February too. */}
              {Array.from({ length: 28 }, (_, i) => i + 1).map((d) => (
                <option key={d} value={d}>
                  day {d}
                </option>
              ))}
            </select>
          ) : null}

          {needsTime ? (
            <select
              className="input"
              value={`${spec.hour}:${spec.minute}`}
              onChange={(e) => {
                const [h, m] = e.target.value.split(":");
                set({ hour: Number(h), minute: Number(m) });
              }}
            >
              {timeOptions().map((t) => (
                <option key={t.value} value={t.value}>
                  {t.label}
                </option>
              ))}
            </select>
          ) : null}

          {spec.frequency === "interval" ? (
            <select
              className="input"
              value={spec.everyMinutes}
              onChange={(e) => set({ everyMinutes: Number(e.target.value) })}
            >
              {[5, 10, 15, 30, 60, 120, 240, 360, 720].map((m) => (
                <option key={m} value={m}>
                  every {m < 60 ? `${m} minutes` : `${m / 60} hour${m === 60 ? "" : "s"}`}
                </option>
              ))}
            </select>
          ) : null}

          {spec.frequency === "custom" ? (
            <input
              className="input"
              value={spec.cron}
              onChange={(e) => set({ cron: e.target.value })}
              placeholder="0 9 * * 1-5"
              style={{ fontFamily: "var(--font-mono)" }}
            />
          ) : null}
        </div>

        {/* Show what was built, in words and in cron. The sentence is what the
            user is agreeing to; the expression is what lands in their repo, and
            hiding it would make a reviewed file a surprise. */}
        <div className="muted" style={{ marginTop: 7 }}>
          {describeCron(cron)} <span style={{ fontFamily: "var(--font-mono)" }}>· {cron}</span>
        </div>
      </div>

      <RoutineWake value={wake} onChange={setWake} />
      {manageError ? (
        <div className="muted" style={{ color: "var(--danger)", marginBottom: 8 }}>{manageError}</div>
      ) : null}

      <div className="stack-row">
        <button className="btn" onClick={() => setOpen(false)} disabled={busy}>
          Cancel
        </button>
        <div style={{ flex: 1 }} />
        <button className="btn btn--primary" onClick={() => void submit()} disabled={busy}>
          {busy ? "Writing…" : "Create"}
        </button>
      </div>
      <div className="muted" style={{ marginTop: 8 }}>
        Saves to the agent’s routine service. Legacy agents may restart to apply changes.
      </div>
    </div>
  );
}

function RestartAgent(): ReactNode {
  const { activeAgentId, agents, portalWorkspaceId } = useStore();
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const restart = async (): Promise<void> => {
    const agent = agents.find(a => a.id === activeAgentId);
    if (!agent?.url || !window.studio) return;
    setBusy(true);
    setMessage("");
    const current = (): boolean => useStore.getState().portalWorkspaceId === portalWorkspaceId && useStore.getState().activeAgentId === activeAgentId;
    try {
      const response = await window.studio.manage({ agentId: agent.id, path: "/tealbrick/management", body: { operation: "restart", requestId: crypto.randomUUID() } });
      if (!current()) return;
      const data = response.data as { ok?: boolean; error?: string } | null;
      setMessage(response.ok && data?.ok
        ? "Restart requested. The agent will briefly disconnect while applying saved changes."
        : "Could not restart the agent. Ask your administrator to check its restart setup.");
    } catch {
      if (current()) setMessage("The restart response was interrupted. Check the agent before retrying.");
    } finally { if (current()) setBusy(false); }
  };
  return <>
    <button className="btn" disabled={busy} onClick={() => void restart()}>{busy ? "Restarting agent…" : "Restart agent"}</button>
    <p className="muted">Applies saved changes and may interrupt running conversations.</p>
    {message && <p role="status" className="card">{message}</p>}
  </>;
}

function Overview(): ReactNode {
  const { agents, activeAgentId, details, models, setPanel, openRoutine, setPluginsOpen, scheduleNotice, infoError, loadAgentInfo } = useStore();
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
          {(info.harness === "codex" || info.capabilities?.includes("session-access")) && <CodexAccess />}
          <p className="muted">Conversations resume the same native {harnessLabel(info)} session. Eve routines and host restart controls do not apply to this harness.</p>
        </Section> : <Section title="Routines" count={loaded ? schedules.length : undefined}>
          {scheduleNotice?.agentId === activeAgentId && <p className="card" role="status">{scheduleNotice.message}</p>}
          <NewRoutine key={`new:${useStore.getState().portalWorkspaceId}:${activeAgentId}`} />
          <RestartAgent key={`restart:${useStore.getState().portalWorkspaceId}:${activeAgentId}`} />
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
          <button className="btn" style={{ flex: 1 }} onClick={() => setPluginsOpen(true)}>
            Plugins
          </button>
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
  const { details, activeAgentId, activeRoutineId, setPanel, deleteSchedule, updateSchedule, manageError } =
    useStore();
  const [confirming, setConfirming] = useState(false);
  const [editing,setEditing]=useState(false);
  const [draftInstruction,setDraftInstruction]=useState("");
  const [draftCron,setDraftCron]=useState("");
  const [editRevision,setEditRevision]=useState<number>();
  useEffect(()=>{const timer=setInterval(()=>void useStore.getState().loadAgentInfo(activeAgentId),15000);return ()=>clearInterval(timer);},[activeAgentId]);
  const [busy, setBusy] = useState(false);
  const schedule = (details[activeAgentId]?.schedules ?? []).find((s) => s.name === activeRoutineId);
  if (!schedule) return null;

  const remove = async (): Promise<void> => {
    setBusy(true);
    const ok = await deleteSchedule(activeAgentId, schedule.name);
    setBusy(false);
    if (ok) setPanel("overview");
  };

  return (
    <>
      <Head title="Routine" onBack={() => setPanel("overview")} onClose={() => setPanel("none")} />
      <div className="panel__body">
        <div className="field">
          <div className="field__label">Name</div>
          <div className="card">{schedule.name}</div>
        </div>

        {schedule.dynamic && <div className="field"><button className="btn" disabled={busy} onClick={()=>{setDraftInstruction(schedule.markdown??"");setDraftCron(schedule.cron??"");setEditRevision(schedule.revision);setEditing(true);}}>Edit routine</button>{" "}<button className="btn" disabled={busy} onClick={async()=>{setBusy(true);await updateSchedule(activeAgentId,schedule.name,{enabled:schedule.enabled===false});setBusy(false);}}>{schedule.enabled===false?"Resume routine":"Pause routine"}</button></div>}
        {editing && <div className="card"><label>Instruction<textarea aria-label="Routine instruction" className="textarea" value={draftInstruction} onChange={e=>setDraftInstruction(e.target.value)}/></label><label>Schedule (UTC cron)<input aria-label="Routine cron" className="input" value={draftCron} onChange={e=>setDraftCron(e.target.value)}/></label><button className="btn" onClick={()=>setEditing(false)}>Cancel</button>{" "}<button className="btn btn--primary" disabled={busy} onClick={async()=>{setBusy(true);const ok=await updateSchedule(activeAgentId,schedule.name,{instruction:draftInstruction,cron:draftCron},editRevision);setBusy(false);if(ok)setEditing(false);}}>Save changes</button></div>}
        <RoutineWake key={`${useStore.getState().portalWorkspaceId}:${activeAgentId}:${schedule.name}`} name={schedule.name} />
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

        {manageError ? (
          <div className="muted" style={{ color: "var(--danger)", marginBottom: 10 }}>{manageError}</div>
        ) : null}

        {confirming ? (
          <div className="card">
            <div style={{ marginBottom: 10 }}>
              Remove this routine? Its saved definition is retained for operator recovery.
            </div>
            <div className="stack-row">
              <button className="btn" onClick={() => setConfirming(false)} disabled={busy}>
                Cancel
              </button>
              <div style={{ flex: 1 }} />
              <button className="btn btn--primary" onClick={() => void remove()} disabled={busy}>
                {busy ? "Removing…" : "Remove routine"}
              </button>
            </div>
          </div>
        ) : (
          <button className="btn" style={{ width: "100%" }} onClick={() => setConfirming(true)}>
            Remove routine
          </button>
        )}

        <div className="muted" style={{ marginTop: 12 }}>
          {schedule.dynamic ? "Desktop and agent tools edit the same host-owned routine. Times use UTC; host wake is optional." : <>Editing happens where the routine lives — ask the agent to change it, or edit{" "}
          <span style={{ fontFamily: "var(--font-mono)" }}>the agent’s authored or extension schedule source</span>{" "}
          in its repository.</>}
        </div>
      </div>
    </>
  );
}

/**
 * The standing answers already given to permission cards, and a way to change them.
 *
 * "Always allow" and "Never" are written to disk the moment they are chosen on
 * a card. The enforcement side has always been able to read and rewrite them;
 * only this screen was missing, so a person who clicked "always" once could
 * never see that they had, let alone take it back. These are per-computer, not
 * per-agent: the permission is about what may happen HERE.
 */
const LOCAL_ACTIONS: { action: LocalAction; label: string; detail: string }[] = [
  { action: "run-command", label: "Run commands", detail: "Shell commands in the working folder." },
  { action: "read-file", label: "Read files", detail: "Read a file from the working folder." },
  { action: "write-file", label: "Write files", detail: "Create or change a file there." },
  { action: "list-directory", label: "List folders", detail: "See what a folder contains." },
  { action: "local-mcp", label: "Use local services", detail: "Call an MCP server running on this computer." },
];

function LocalPermissions(): ReactNode {
  const [perms, setPerms] = useState<Record<LocalAction, LocalPermission> | null>(null);

  useEffect(() => {
    let live = true;
    void window.studio?.localPermissions().then((p) => live && setPerms(p));
    return () => {
      live = false;
    };
  }, []);

  const set = async (action: LocalAction, value: LocalPermission): Promise<void> => {
    const next = await window.studio?.setLocalPermission({ action, value });
    if (next) setPerms(next);
  };

  if (!perms) return null;
  const standing = LOCAL_ACTIONS.filter((a) => perms[a.action] !== "ask").length;

  return (
    <div className="card">
      <div className="stack-row">
        <div style={{ flex: 1 }}>
          <div>What agents may do on this computer</div>
          <div className="muted">
            {standing === 0
              ? "Every one of these asks first. Answering “always” or “never” on a card is remembered here."
              : `${standing} of these no longer ask. Set one back to “Ask” to be prompted again.`}
          </div>
        </div>
      </div>
      {LOCAL_ACTIONS.map((a) => (
        <div key={a.action} className="stack-row" style={{ marginTop: 10 }}>
          <div style={{ flex: 1 }}>
            <div>{a.label}</div>
            <div className="muted">{a.detail}</div>
          </div>
          <select
            className="input"
            style={{ maxWidth: 110 }}
            value={perms[a.action]}
            onChange={(e) => void set(a.action, e.target.value as LocalPermission)}
          >
            <option value="ask">Ask</option>
            <option value="always">Always</option>
            <option value="never">Never</option>
          </select>
        </div>
      ))}
    </div>
  );
}

/**
 * One switch for "this agent may work on this computer".
 *
 * Everything underneath it — minting the agent's credential, installing it,
 * recording the standing permission — happens between the control plane, this
 * app, and the agent. None of it is a step for the person, and the credential
 * is never shown, because a setup that asks someone to carry a secret between
 * two screens is a setup that will be done wrong or not at all.
 */
function LocalAccess({ agent, agentId, url }: { agent: string; agentId: string; url?: string }): ReactNode {
  const [on, setOn] = useState<boolean | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let live = true;
    void window.studio?.localAccess(agent).then((v) => live && setOn(v));
    return () => {
      live = false;
    };
  }, [agent]);

  const toggle = async (next: boolean): Promise<void> => {
    if (!url) return;
    setBusy(true);
    setError(null);
    try {
      if (next) {
        const res = await window.studio!.provisionLocal({ agentId });
        if (!res.ok) {
          setError(res.error ?? "Could not connect it to this computer.");
          return;
        }
        setOn(true);
      } else {
        await window.studio!.revokeLocal(agent);
        setOn(false);
      }
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="card stack-row">
      <div style={{ flex: 1 }}>
        <div>Work on this computer</div>
        <div className="muted">
          {error
            ? error
            : busy
              ? "Setting it up…"
              : on
                ? "Allowed on this Mac. It stays allowed until you turn this off."
                : "Let this agent read and change files here, and run commands."}
        </div>
      </div>
      <Toggle on={on === true} onChange={(v) => void toggle(v)} />
    </div>
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

        <LocalAccess agent={info?.name ?? agent.name} agentId={agent.id} url={agent.url} />

        <LocalPermissions />

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

        {hasLiveVoiceTransport() && (
          <div className="card stack-row">
            <div style={{ flex: 1 }}>
              <div>Voice</div>
              <div className="muted">The spoken voice for this agent's floating voice orb.</div>
            </div>
            <select
              className="input"
              style={{ maxWidth: 130 }}
              value={agent.voice ?? "marin"}
              onChange={(e) => patchAgent(agent.id, { voice: e.target.value })}
            >
              {/* Every voice the Live API accepts, in OpenAI's order of preference;
                  marin and cedar are the two it recommends for quality. There is no
                  endpoint that reports them, so this list is held here and on the phone. */}
              {["marin", "cedar", "alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse"].map((v) => (
                <option key={v} value={v}>
                  {v === "marin" || v === "cedar" ? `${v} — recommended` : v}
                </option>
              ))}
            </select>
          </div>
        )}

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
