import { type ReactNode, useEffect, useRef, useState } from "react";
import { useStore } from "@/lib/store";
import { Icon } from "./primitives";
import type { ControlPlaneState } from "@shared/controlPlanes";

/**
 * Device-flow sign-in (RFC 8628).
 *
 * The user approves in a browser against the Teal Brick Portal, and the
 * identity token that comes back is what every agent's HTTP door verifies. That
 * means Studio access is governed by exactly the same grants as Slack and
 * iMessage — revoke someone in the control plane and the desktop goes with it.
 *
 * The user code is shown in the app as well as opened in the browser, because
 * an auto-opened tab that lands on the wrong profile is common and the code is
 * then the only way to finish.
 *
 * Everything below the code exists because that "wrong profile" case had no way
 * out. The code is good for ten minutes, and those minutes used to be
 * unconditional: no cancel, no countdown, and no way to reopen a tab that had
 * been closed. Waiting is a reasonable thing to ask of someone only when they
 * can see how long is left and stop.
 */
export function SignIn(): ReactNode {
  const { signIn, cancelSignIn, authError } = useStore();
  const [code, setCode] = useState<string | null>(null);
  const [url, setUrl] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [copied, setCopied] = useState(false);
  const [left, setLeft] = useState<number | null>(null);
  const deadline = useRef<number | null>(null);
  const [planes, setPlanes] = useState<ControlPlaneState | null>(null);
  const [planeError, setPlaneError] = useState<string | null>(null);
  const [switching, setSwitching] = useState(false);
  const [adding, setAdding] = useState(false);
  const [name, setName] = useState("");
  const [issuer, setIssuer] = useState("");
  const active = planes?.profiles.find((p) => p.id === planes.activeId);

  useEffect(() => {
    void window.studio?.controlPlanes().then(setPlanes).catch((e: unknown) => setPlaneError(String(e)));
  }, []);

  const changePlane = async (action: () => Promise<unknown>): Promise<void> => {
    setSwitching(true);
    setPlaneError(null);
    try { await action(); }
    catch (e) { setPlaneError(e instanceof Error ? e.message : String(e)); }
    finally { setSwitching(false); }
  };

  useEffect(() => {
    if (!code) {
      setLeft(null);
      return;
    }
    // Ten minutes, matching the control plane's expiry. Shown rather than
    // implied: a countdown turns "waiting…" into a decision the person can make.
    deadline.current = Date.now() + 600_000;
    const tick = (): void =>
      setLeft(Math.max(0, Math.round(((deadline.current ?? 0) - Date.now()) / 1000)));
    tick();
    const timer = setInterval(tick, 1000);
    return () => clearInterval(timer);
  }, [code]);

  const begin = async (): Promise<void> => {
    setBusy(true);
    setCopied(false);
    try {
      const started = await signIn((c, verificationUri) => {
        setCode(c);
        setUrl(verificationUri ?? null);
      });
      if (!started) {
        setCode(null);
        setUrl(null);
      }
    } finally {
      setBusy(false);
    }
  };

  const startAgain = async (): Promise<void> => {
    await cancelSignIn();
    setCode(null);
    setUrl(null);
    setCopied(false);
    await begin();
  };

  const expired = left === 0;

  return (
    <div className="signin">
      <div className="signin__card">
        <img className="signin__mark" src="./brand/teal-brick-colour.png" alt="" />
        <h1 className="signin__title">Teal Brick</h1>
        <p className="signin__sub">
          Connect to Teal Brick Portal or your own self-hosted portal.
        </p>

        {planes ? (
          <div className="signin__planes">
            <label htmlFor="control-plane">Portal</label>
            <select id="control-plane" value={planes.activeId} disabled={busy || switching}
              onChange={(e) => void changePlane(() => window.studio!.activateControlPlane(e.target.value))}>
              {planes.profiles.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
            </select>
            <p className="signin__hint">Switching resets Chat only. Each portal keeps its own data and sign-in.</p>
            {!code && !adding ? (
              <button className="btn" disabled={busy || switching} onClick={() => setAdding(true)}>Add self-hosted portal</button>
            ) : null}
            {adding ? (
              <form className="signin__plane-form" onSubmit={(e) => {
                e.preventDefault();
                void changePlane(() => window.studio!.addControlPlane({ name, issuer }));
              }}>
                <label htmlFor="plane-name">Name</label>
                <input id="plane-name" value={name} onChange={(e) => setName(e.target.value)} required maxLength={64} disabled={switching} placeholder="My self-hosted portal" />
                <label htmlFor="plane-url">Portal URL</label>
                <input id="plane-url" type="url" value={issuer} onChange={(e) => setIssuer(e.target.value)} required disabled={switching} placeholder="https://portal.your-company.com" />
                <div className="signin__actions">
                  <button className="btn" type="button" onClick={() => setAdding(false)} disabled={switching}>Cancel</button>
                  <button className="btn btn--primary" type="submit" disabled={switching}>Add and switch</button>
                </div>
              </form>
            ) : null}
          </div>
        ) : null}

        {code ? (
          <>
            <button
              className="signin__code"
              title="Copy the code"
              onClick={() => {
                void navigator.clipboard.writeText(code);
                setCopied(true);
              }}
            >
              {code}
            </button>
            <p className="signin__hint">
              {expired
                ? "That code expired. Start again for a new one."
                : copied
                  ? "Copied. Approve it in your browser."
                  : "Approve this code in your browser. Waiting…"}
              {!expired && left !== null ? (
                <span className="signin__left">
                  {" "}
                  {Math.floor(left / 60)}:{String(left % 60).padStart(2, "0")} left
                </span>
              ) : null}
            </p>
            <div className="signin__actions">
              {url && !expired ? (
                <button
                  className="btn"
                  onClick={() => void window.studio?.openExternal(url)}
                  title="Open the approval page again"
                >
                  Open browser
                </button>
              ) : null}
              <button className="btn" onClick={() => void startAgain()} disabled={busy}>
                Start again
              </button>
              <button className="btn" onClick={async () => {
                await cancelSignIn(); setCode(null); setUrl(null); setBusy(false);
              }}>Cancel sign-in</button>
            </div>
          </>
        ) : (
          <button className="btn btn--primary signin__btn" onClick={begin} disabled={busy || switching || adding || !planes}>
            {busy ? "Opening your browser…" : "Sign in"}
          </button>
        )}

        {authError || planeError ? (
          <div className="signin__error" role="alert">
            <Icon name="close" size={13} /> {planeError ?? authError}
          </div>
        ) : null}

        <div className="signin__issuer">{active?.issuer ?? useStore.getState().issuer}</div>
      </div>
    </div>
  );
}

