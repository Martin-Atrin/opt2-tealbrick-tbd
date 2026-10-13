import { type KeyboardEvent, type ReactNode, useCallback, useEffect, useId, useRef, useState } from "react";
import { createPortal } from "react-dom";

/**
 * StepFlow (kit C126 + C128): every multi-step popup in Chat. ONE step at a time, ONE fixed size for all
 * steps (only the middle scrolls). Top: the step row "1-Name 2-Name ..." as a nav (current = aria-current="step",
 * done = teal-ink with a check and a button back, upcoming = ink at 62%). Bottom: Previous (left),
 * Skip (only on an optional step, with its own label), Next (right, labelled with the step's action).
 * A step change fades the middle out (ease-in) and the next in (ease-out); instant with reduced motion.
 */

export interface StepFlowStep {
  /** The name in the step row. */
  name: string;
  /** The heading of the step (focused when the step opens). */
  title: string;
  /** Present only on an optional step: Skip's own label, e.g. "Skip, connect later". */
  skip?: string;
  /** Next's label: the step's action ("Connect", "Done"). Default "Next". */
  next?: string;
  /** Shows the check once the flow is past this step. Default true; false when the step is still open in fact. */
  done?: boolean;
  /** Next cannot be pressed yet (e.g. waiting for an approval). */
  nextDisabled?: boolean;
  render(): ReactNode;
}

export interface StepFlowProps {
  /** Small line above the title. */
  kicker?: string;
  title: string;
  steps: StepFlowStep[];
  /** Controlled step (the flow moves itself on async events); omit to let the flow keep the step. */
  step?: number;
  onStepChange?(step: number): void;
  /** Before Next moves on. Return false to stay (the caller then moves the step itself, if at all). */
  beforeNext?(step: number): boolean | void | Promise<boolean | void>;
  /** Before Previous or a done step moves back. Return false to stay. */
  beforeBack?(from: number, to: number): boolean | void | Promise<boolean | void>;
  /** Next (or Skip) on the last step. */
  onFinish(): void;
  /** Close button and Escape. */
  onClose(): void;
}

const FOCUSABLE = 'button:not(:disabled), [href], input:not(:disabled), select:not(:disabled), textarea:not(:disabled), [tabindex]:not([tabindex="-1"])';

function reducedMotion(): boolean {
  return typeof window.matchMedia === "function" && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
}

/** --tb-dur-step ("200ms") of the dialog, in milliseconds. */
function stepDuration(el: HTMLElement | null): number {
  const raw = el ? getComputedStyle(el).getPropertyValue("--tb-dur-step").trim() : "";
  const n = Number.parseFloat(raw);
  if (!Number.isFinite(n)) return 200;
  return raw.endsWith("ms") ? n : n * 1000;
}

export function StepFlow({ kicker, title, steps, step, onStepChange, beforeNext, beforeBack, onFinish, onClose }: StepFlowProps): ReactNode {
  const titleId = useId();
  const dialogRef = useRef<HTMLElement>(null);
  const stepTitleRef = useRef<HTMLHeadingElement>(null);
  const busy = useRef(false);
  const opener = useRef<Element | null>(typeof document === "undefined" ? null : document.activeElement);
  const [own, setOwn] = useState(0);
  const last = steps.length - 1;
  const target = Math.min(last, Math.max(0, step ?? own));
  const [shown, setShown] = useState(target);
  const [leaving, setLeaving] = useState(false);
  const opened = useRef(false);

  const setStep = useCallback((k: number): void => {
    if (step === undefined) setOwn(k);
    onStepChange?.(k);
  }, [step, onStepChange]);

  // Fade out, swap, fade in. Reduced motion: swap at once.
  useEffect(() => {
    if (shown === target) return;
    if (reducedMotion()) { setShown(target); return; }
    setLeaving(true);
    const timer = window.setTimeout(() => { setShown(target); setLeaving(false); }, stepDuration(dialogRef.current));
    return () => window.clearTimeout(timer);
  }, [target, shown]);

  // A new step takes focus on its heading; the first step takes focus on the dialog itself.
  useEffect(() => {
    if (!opened.current) { opened.current = true; dialogRef.current?.focus(); return; }
    stepTitleRef.current?.focus();
  }, [shown]);

  // Focus goes back to where it was when the flow closes.
  useEffect(() => () => {
    const from = opener.current;
    if (from instanceof HTMLElement && from.isConnected) from.focus();
  }, []);

  const guarded = async (run: () => boolean | void | Promise<boolean | void>, then: () => void): Promise<void> => {
    if (busy.current) return;
    busy.current = true;
    try {
      if ((await run()) === false) return;
      then();
    } finally {
      busy.current = false;
    }
  };
  const back = (to: number): Promise<void> => guarded(() => beforeBack?.(shown, to), () => setStep(to));
  const next = (): Promise<void> => guarded(() => beforeNext?.(shown), () => (shown >= last ? onFinish() : setStep(shown + 1)));
  const skip = (): void => (shown >= last ? onFinish() : setStep(shown + 1));

  const onKeyDown = (e: KeyboardEvent<HTMLElement>): void => {
    if (e.key === "Escape") { e.stopPropagation(); onClose(); return; }
    if (e.key !== "Tab") return;
    const items = [...(dialogRef.current?.querySelectorAll<HTMLElement>(FOCUSABLE) ?? [])];
    if (items.length === 0) return;
    const first = items[0], end = items[items.length - 1];
    const at = document.activeElement;
    if (e.shiftKey && (at === first || at === dialogRef.current)) { e.preventDefault(); end.focus(); }
    else if (!e.shiftKey && at === end) { e.preventDefault(); first.focus(); }
  };

  const current = steps[shown] ?? steps[0];
  if (!current) return null;
  return createPortal(
    <div className="tb-scrim">
      <section ref={dialogRef} className="tb-dialog tb-stepflow" role="dialog" aria-modal="true" aria-labelledby={titleId} tabIndex={-1} onKeyDown={onKeyDown}>
        <div className="tb-dialog-head">
          {kicker ? <p className="tb-kicker">{kicker}</p> : null}
          <button type="button" className="tb-close" onClick={onClose}>Close</button>
          <h2 id={titleId}>{title}</h2>
          <nav className="tb-stepflow-nav" aria-label="Steps">
            <ol className="tb-stepflow-steps">
              {steps.map((s, k) => (
                <li key={s.name} className={k < shown && s.done !== false ? "done" : undefined} aria-current={k === shown ? "step" : undefined}>
                  <button type="button" disabled={k > shown} onClick={() => { if (k < shown) void back(k); }}>{k + 1}-{s.name}</button>
                </li>
              ))}
            </ol>
          </nav>
        </div>
        <div className={`tb-dialog-body${leaving ? " is-leaving" : ""}`}>
          <section className="tb-step" aria-labelledby={`${titleId}-step`}>
            <h3 id={`${titleId}-step`} ref={stepTitleRef} tabIndex={-1}>{current.title}</h3>
            {current.render()}
          </section>
        </div>
        <div className="tb-dialog-foot tb-stepflow-foot">
          <button type="button" className="btn" disabled={shown === 0} onClick={() => void back(shown - 1)}>Previous</button>
          {current.skip ? <button type="button" className="btn btn--quiet" onClick={skip}>{current.skip}</button> : null}
          <button type="button" className="btn btn--primary tb-next" disabled={current.nextDisabled} onClick={() => void next()}>{current.next ?? "Next"}</button>
        </div>
      </section>
    </div>,
    document.body,
  );
}
