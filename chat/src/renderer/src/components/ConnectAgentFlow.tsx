import { type ReactNode, useEffect, useRef, useState } from "react";
import { StepFlow, type StepFlowStep } from "./StepFlow";

/**
 * "Connect TBD's agent" (C24) as a StepFlow: start, approve in the browser, done. Same IPC as before:
 * agentConnect starts the device flow and returns the code, awaitAgentConnect resolves when the owner
 * has approved it, cancelAgentConnect stops waiting. The key stays in this Mac's Keychain.
 */
const START = 0, APPROVE = 1, DONE = 2;

export function ConnectAgentFlow({ onClose, onConnected }: { onClose(): void; onConnected(): void }): ReactNode {
  const [step, setStep] = useState(START);
  const [code, setCode] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const alive = useRef(true);
  useEffect(() => {
    alive.current = true;
    return () => { alive.current = false; };
  }, []);

  const connect = async (): Promise<void> => {
    setError(null);
    try {
      const start = await window.studio.agentConnect();
      if (!alive.current) return;
      setCode(start.userCode);
      setStep(APPROVE);
      await window.studio.awaitAgentConnect();
      if (!alive.current) return;
      setCode(null);
      setStep(DONE);
      onConnected();
    } catch (e) {
      if (!alive.current) return;
      setCode(null);
      setStep(START);
      setError(e instanceof Error ? e.message : String(e));
    }
  };
  const cancel = (): void => {
    void window.studio.cancelAgentConnect();
    setCode(null);
    setStep(START);
  };
  // Closing or going back while the browser approval is pending ends the wait, as Cancel did.
  const close = (): void => {
    if (step === APPROVE) void window.studio.cancelAgentConnect();
    onClose();
  };

  const steps: StepFlowStep[] = [
    {
      name: "Connect",
      title: "Connect TBD's agent to your workspace",
      next: "Connect",
      render: () => (
        <>
          <p className="tb-soft">Connect TBD&apos;s agent to your workspace to use memory and connected accounts.</p>
          {error ? <p className="tb-error" role="alert">{error}</p> : null}
        </>
      ),
    },
    {
      name: "Approve",
      title: "Approve in your browser",
      next: "Waiting for approval",
      nextDisabled: true,
      render: () => (
        <>
          <p className="tb-soft">Approve in your browser. Code: <span className="tb-code">{code}</span></p>
          <div className="tb-row"><button type="button" className="btn" onClick={cancel}>Cancel</button></div>
        </>
      ),
    },
    {
      name: "Done",
      title: "Connected",
      next: "Done",
      render: () => <p className="tb-soft">Connected. Teal Brick apps are available to TBD&apos;s agent.</p>,
    },
  ];
  return (
    <StepFlow
      title="Connect TBD's agent"
      kicker="Teal Brick workspace"
      steps={steps}
      step={step}
      onStepChange={setStep}
      beforeNext={(from) => {
        if (from === START) { void connect(); return false; }
      }}
      beforeBack={(from) => {
        if (from === APPROVE) { cancel(); return false; }
        if (from === DONE) return false; // connected: nothing to go back to
      }}
      onFinish={onClose}
      onClose={close}
    />
  );
}
