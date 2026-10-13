import { type ReactNode, useCallback, useEffect, useState } from "react";
import type { FirstRunState } from "@shared/ipc";
import { firstRunSteps, showFirstRun } from "../lib/firstRun";
import { useStore } from "@/lib/store";

/**
 * First-run checks above the conversation (PARITY WP5): what TBD's agent still needs, each with
 * the one control that fixes it. Re-checked when the window regains focus (back from Settings).
 */
export function FirstRunChecks({ conversationEmpty }: { conversationEmpty: boolean }): ReactNode {
  const [state, setState] = useState<FirstRunState | null>(null);
  const setPanel = useStore((s) => s.setPanel);
  const refreshAgents = useStore((s) => s.refreshAgents);
  const check = useCallback((): void => {
    void window.studio.firstRun().then(setState).catch(() => setState(null));
  }, []);
  useEffect(() => {
    check();
    window.addEventListener("focus", check);
    return () => window.removeEventListener("focus", check);
  }, [check]);
  if (!state) return null;
  const steps = firstRunSteps(state);
  if (!showFirstRun(steps, conversationEmpty)) return null;
  return (
    <section className="card" aria-label="Set up TBD's agent" style={{ margin: "10px 0" }}>
      <div style={{ marginBottom: 6 }}>Set up TBD&apos;s agent</div>
      {steps.map((step) => (
        <div key={step.id} className="stack-row" style={{ marginTop: 6 }}>
          <span aria-hidden="true" style={{ width: 18 }}>{step.done ? "✓" : "○"}</span>
          <div style={{ flex: 1 }}>
            <div>{step.title}</div>
            {step.detail ? <div className="muted">{step.detail}</div> : null}
          </div>
          {step.action === "models" ? (
            <button type="button" className="btn btn--primary" onClick={() => void window.studio.openSettings("engine")}>Open Settings → Models</button>
          ) : step.action === "connect" ? (
            <button type="button" className="btn" onClick={() => setPanel("overview")}>Connect…</button>
          ) : null}
        </div>
      ))}
      <div className="stack-row" style={{ marginTop: 8 }}>
        <button type="button" className="btn" onClick={() => { check(); void refreshAgents({ refreshSession: false }); }}>Check again</button>
      </div>
    </section>
  );
}
