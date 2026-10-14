import type { CSSProperties, ReactNode } from "react";
import type { Agent } from "@shared/types";
import { agentCardModel } from "@/lib/agentCard";
import { harnessLabel } from "@/lib/agentInfo";
import { NO_MODEL_TITLE, modelGate } from "@/lib/agentModel";
import { type TbdApp, tbdApp } from "@/lib/apps.generated";
import { useStore } from "@/lib/store";

/** The kit's AppIcon: the app's production still, a square brick crop on its spot paper (16/24/32/48). */
export function AppIcon({ app, size = 16 }: { app: TbdApp; size?: 16 | 24 | 32 | 48 }): ReactNode {
  const still = `./brand/apps/${app.slug}`;
  const style: CSSProperties = { backgroundImage: `image-set(url(${still}@1x.webp) 1x, url(${still}@2x.webp) 2x)` };
  return <span className={`tb-app-icon s${size}`} style={style} aria-hidden="true" />;
}

/** One connected app: AppIcon 16 and its name in white on the app's own colour (AA, tools/app-colors.ts). */
export function AppChip({ id }: { id: string }): ReactNode {
  const app = tbdApp(id);
  if (!app) return null;
  return (
    <span className="tbd-app-chip" style={{ background: app.color }}>
      <AppIcon app={app} size={16} />
      {app.name}
    </span>
  );
}

/**
 * The canvas agent card (C146): initial avatar, name, "harness · mode" line, status pill and, when the
 * data names them, the agent's connected apps. Read only; the caller makes it a button where it acts.
 */
export function AgentCard({ agent, selected = false, wide = false, appIds }: { agent: Agent; selected?: boolean; wide?: boolean; appIds?: readonly string[] }): ReactNode {
  const info = useStore((s) => s.details[agent.id]);
  const busy = useStore((s) => Boolean(s.inflight[agent.id]));
  const blocked = useStore((s) => modelGate(agent.id, s.agentModel).blocked);
  const model = agentCardModel(agent, {
    harness: info ? harnessLabel(info) : undefined,
    modelBlocked: blocked ? NO_MODEL_TITLE : undefined,
    busy,
    appIds,
  });
  return (
    <div className={`tbd-agent-card${selected ? " is-selected" : ""}${wide ? " is-wide" : ""}`} data-selected={selected}>
      <div className="tbd-agent-card__row">
        <span className="tbd-agent-card__avatar" aria-hidden="true">{model.initial}</span>
        <span className="tbd-agent-card__name">{model.name}</span>
      </div>
      <div className="tbd-agent-card__meta">
        {model.harness ? <span>{model.harness}</span> : null}
        {model.status ? <span className={`tb-tag ${model.status.kind}`}>{model.status.text}</span> : null}
      </div>
      {model.appIds.length > 0 ? (
        <div className="tbd-agent-card__apps">
          {model.appIds.map((id) => <AppChip key={id} id={id} />)}
        </div>
      ) : null}
    </div>
  );
}
