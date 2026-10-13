import type { ReactNode } from "react";
import type { Agent } from "@shared/types";
import { CHAT_COMES_NEXT, workspaceAgentSubtitle } from "@/lib/workspaceAgents";
import { Avatar } from "./primitives";

/** Another agent of the Portal workspace (C127): its card, read only. No composer: chat comes next. */
export function WorkspaceAgentView({ agent }: { agent: Agent }): ReactNode {
  const info = agent.workspace;
  if (!info) return <div className="main" />;
  return (
    <div className="main" style={{ position: "relative" }}>
      <div className="topbar">
        <Avatar name={agent.name} accent={agent.accent} src={agent.avatar} size={22} />
        <span className="topbar__title">{agent.name}</span>
        <span className="muted" style={{ marginLeft: 8 }}>{workspaceAgentSubtitle(info)}</span>
        <div className="topbar__spacer" />
      </div>
      <section className="card" aria-label={`About ${agent.name}`} style={{ margin: "16px" }}>
        {info.purpose ? <p>{info.purpose}</p> : null}
        <p className="muted" role="note">{CHAT_COMES_NEXT}</p>
      </section>
    </div>
  );
}
