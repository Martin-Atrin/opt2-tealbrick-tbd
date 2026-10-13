import { type ReactNode, useCallback, useEffect, useState } from "react";
import type { FirstRunState } from "@shared/ipc";
import { type FirstRunStep, firstRunSteps, showFirstRun } from "../lib/firstRun";
import { useStore } from "@/lib/store";
import { StepFlow, type StepFlowStep } from "./StepFlow";

/** Closed with Close or Done: stays closed in this session (it comes back on the next launch if still needed). */
let closedThisSession = false;

function StateTag({ step }: { step: FirstRunStep }): ReactNode {
  if (step.done) return <span className="tb-tag live">Done</span>;
  return step.optional ? <span className="tb-tag open">Optional</span> : <span className="tb-tag needs-you">Needs you</span>;
}

/**
 * First-run flow (PARITY WP5) as a StepFlow: what TBD's agent still needs, one step each, with the
 * one control that fixes it. Re-checked when the window regains focus (back from Settings).
 */
export function FirstRunChecks({ conversationEmpty }: { conversationEmpty: boolean }): ReactNode {
  const [state, setState] = useState<FirstRunState | null>(null);
  const [closed, setClosed] = useState(closedThisSession);
  const setPanel = useStore((s) => s.setPanel);
  const refreshAgents = useStore((s) => s.refreshAgents);
  const checkAgentModel = useStore((s) => s.checkAgentModel);
  // One check feeds this flow and the "No model set" note on the row and in the composer.
  const check = useCallback((): void => {
    void checkAgentModel().then(setState);
  }, [checkAgentModel]);
  useEffect(() => {
    check();
    window.addEventListener("focus", check);
    return () => window.removeEventListener("focus", check);
  }, [check]);
  if (!state || closed) return null;
  const steps = firstRunSteps(state);
  if (!showFirstRun(steps, conversationEmpty)) return null;
  const close = (): void => { closedThisSession = true; setClosed(true); };

  const checkAgain = (): ReactNode => (
    <div className="tb-row">
      <button type="button" className="btn" onClick={() => { check(); void refreshAgents({ refreshSession: false }); }}>Check again</button>
    </div>
  );
  const flowSteps: StepFlowStep[] = steps.map((step, i) => ({
    name: step.name,
    title: step.title,
    done: step.done,
    next: i === steps.length - 1 ? "Done" : "Next",
    render: () => (
      <>
        <div className="tb-row"><StateTag step={step} /></div>
        {step.detail ? <p className="tb-soft">{step.detail}</p> : null}
        {step.action === "models" ? (
          <div className="tb-row"><button type="button" className="btn" onClick={() => void window.studio.openSettings("engine")}>Open Settings → Models</button></div>
        ) : step.action === "connect" ? (
          <div className="tb-row"><button type="button" className="btn" onClick={() => { setPanel("overview"); close(); }}>Connect…</button></div>
        ) : null}
        {step.id !== "signin" ? checkAgain() : null}
      </>
    ),
  }));
  // Open on the first thing that is still missing.
  return <FirstRunFlow steps={flowSteps} start={Math.max(0, steps.findIndex((s) => !s.done))} onClose={close} />;
}

function FirstRunFlow({ steps, start, onClose }: { steps: StepFlowStep[]; start: number; onClose(): void }): ReactNode {
  const [at, setAt] = useState(start);
  return <StepFlow title="Set up TBD's agent" steps={steps} step={Math.min(at, steps.length - 1)} onStepChange={setAt} onFinish={onClose} onClose={onClose} />;
}
