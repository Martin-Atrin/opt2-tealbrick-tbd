import { WorkspacePicker } from "./components/WorkspacePicker";
import { type ReactNode, useEffect } from "react";
import { Conversation } from "./components/Conversation";
import { WorkspaceAgentView } from "./components/WorkspaceAgent";
import { Palette } from "./components/Palette";
import { Panel } from "./components/Panel";
import { Sidebar } from "./components/Sidebar";
import { SignIn } from "./components/SignIn";
import { useStore } from "./lib/store";

export function App(): ReactNode {
  const { portalWorkspaceId, workspaceLoading, setPaletteOpen, paletteOpen, bootstrap, authState, agents, authError, refreshAgents } = useStore();

  useEffect(() => {
    void bootstrap();
  }, [bootstrap]);

  // Follow the open thread live while nothing of ours is in flight in it.
  const activeAgentId = useStore((s) => s.activeAgentId);
  const activeWorkspaceAgent = agents.find((a) => a.id === activeAgentId && a.workspace);
  const activeSession = useStore((s) => (s.activeAgentId ? s.sessions[s.activeAgentId] : undefined));
  const activeInflight = useStore((s) => (s.activeAgentId ? Boolean(s.inflight[s.activeAgentId]) : false));
  const watchActive = useStore((s) => s.watchActive);
  const stopWatching = useStore((s) => s.stopWatching);
  useEffect(() => {
    if (authState !== "signed-in" || !portalWorkspaceId || workspaceLoading) return;
    watchActive();
  }, [authState, portalWorkspaceId, workspaceLoading, activeAgentId, activeSession, activeInflight, watchActive]);
  useEffect(() => () => stopWatching(), [stopWatching]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent): void => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        setPaletteOpen(!paletteOpen);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [paletteOpen, setPaletteOpen]);

  if (authState === "loading") return <main className="tb-empty" role="status">Opening TBD Chat…</main>;

  if (authState === "signed-out") return <SignIn />;
  if (workspaceLoading || !portalWorkspaceId) return <WorkspacePicker />;

  return (
    <div className="app">
      <Sidebar />
      {agents.length === 0 ? <main className="tb-empty">
        <img src="./brand/teal-brick-colour.png" width="48" height="48" alt="" />
        <h1>Your agents will appear here</h1>
        <p role="status">{authError ?? "Loading the agents available to your account…"}</p>
        <button className="btn" onClick={() => void refreshAgents({ refreshSession: true })}>Refresh agents</button>
      </main> : activeWorkspaceAgent ? <WorkspaceAgentView agent={activeWorkspaceAgent} /> : <Conversation />}
      <Panel />
      <Palette />
    </div>
  );
}
