// Dev-only entry for scripts/design-proof.ts: the REAL renderer App on top of a FAKE window.studio.
// Same import order as src/renderer/src/main.tsx (App, ErrorBoundary, styles.css, teal-brick.css).
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "@/App";
import { ErrorBoundary } from "@/components/ErrorBoundary";
import { useStore } from "@/lib/store";
import "@/styles.css";
import "@/teal-brick.css";
import { UNREAD_AGENT_ID, installStudio } from "./fixtures";

// The store only touches window.studio from effects, but install before the first render anyway.
installStudio();

createRoot(document.getElementById("root") as HTMLElement).render(
  <StrictMode>
    <ErrorBoundary>
      <App />
    </ErrorBoundary>
  </StrictMode>,
);

// "Needs attention" is local renderer state (set when a message lands in a non-active thread), not
// something the control plane sends, so mark one workspace agent unread through the store.
// refreshAgents carries `unread` over from the previous roster, so it survives the 60 s refresh.
const markUnread = useStore.subscribe((s) => {
  if (!s.agents.some((a) => a.id === UNREAD_AGENT_ID)) return;
  markUnread();
  s.patchAgent(UNREAD_AGENT_ID, { unread: true });
});
