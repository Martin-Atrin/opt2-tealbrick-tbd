// Proof-only sheet (?sample=apps): the data model names no apps for any agent, so this is the only place the
// app chip and AppIcon sizes are exercised (shots + contrast). It is never part of the app.
import type { ReactNode } from "react";
import type { Agent } from "@shared/types";
import { AgentCard, AppChip, AppIcon } from "@/components/AgentCard";
import { TBD_APPS } from "@/lib/apps.generated";

const agent = (id: string, name: string, state: "online" | "paused", harness: string): Agent => ({
  id, name, url: "", accent: "var(--tb-tone-teal)", status: state === "online" ? "online" : "offline",
  workspace: { purpose: "", state, harness },
});

export function AppsSample(): ReactNode {
  return (
    <main className="app-sample" style={{ display: "grid", gap: 24, padding: 32, background: "var(--tb-paper)", color: "var(--tb-ink)", minHeight: "100vh", alignContent: "start" }}>
      <section style={{ display: "flex", gap: 16, alignItems: "start", flexWrap: "wrap" }}>
        <AgentCard agent={agent("a", "Front desk", "online", "Claude Code")} appIds={["knowledge", "kanban", "inbox"]} />
        <AgentCard agent={agent("b", "Research partner", "online", "Codex")} selected appIds={["knowledge", "rules"]} />
        <AgentCard agent={agent("c", "Night shift", "paused", "Eve")} />
      </section>
      <section style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
        {TBD_APPS.map((a) => <AppChip key={a.id} id={a.id} />)}
      </section>
      <section style={{ display: "flex", gap: 12, alignItems: "center" }}>
        {TBD_APPS.slice(0, 3).flatMap((a) => ([16, 24, 32, 48] as const).map((n) => <AppIcon key={`${a.id}${n}`} app={a} size={n} />))}
      </section>
    </main>
  );
}
