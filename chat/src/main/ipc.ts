import { portalWorkspaces, selectPortalWorkspace, scopedStateName } from "./portalWorkspaces";
import { publicSession } from "./portalPrivacy";
import { app, BrowserWindow, Notification, ipcMain, shell, type WebContents } from "electron";
import { activateControlPlane, addControlPlane, controlPlanes, removeControlPlane } from "./controlPlanes";
import { assertPlaneSwitchAllowed } from "./controlPlaneProfiles";
import type { Attachment } from "../shared/ipc";
import { loadState, pickFolder, saveState } from "./store";
import {
  localFileExists,
  openLocalFile,
  openRemoteFile,
  revealLocalFile,
  saveRemoteFile,
} from "./deliveredFile";
import { replaySession } from "./sessionIndex";
import { answerAsk } from "./asks";
import {
  type DeviceStart,
  agentHealth,
  agentInfo,
  cancelTurn,
  currentSession,
  listAgents,
  saveAgentProfile,
  watchSession,
  pollDeviceAuth,
  resetSession,
  sendTurn,
  signOut,
  startDeviceAuth,
  cancelDeviceAuth,
} from "./controlPlane";

/**
 * The device flow spans two calls — start (show the code) and await (poll) — so
 * the UI can display the user code while the browser round-trip happens. The
 * pending start is held here rather than round-tripped through the renderer, so
 * a device code never sits in web content.
 */
let pending: DeviceStart | null = null;
let startingSignIn = false;

export function registerIpc(): void {
  ipcMain.handle("studio:portalWorkspaces", () => portalWorkspaces());
  ipcMain.handle("studio:selectPortalWorkspace", (_e, id: string) => selectPortalWorkspace(id));
  const requireSignedOut = (): void => assertPlaneSwitchAllowed(Boolean(currentSession()), startingSignIn || Boolean(pending));
  ipcMain.handle("studio:controlPlanes", () => controlPlanes());
  ipcMain.handle("studio:activateControlPlane", (_e, id: string) => { requireSignedOut(); activateControlPlane(id); });
  ipcMain.handle("studio:addControlPlane", (_e, input: { name: string; issuer: string }) => { requireSignedOut(); addControlPlane(input); });
  ipcMain.handle("studio:removeControlPlane", (_e, id: string) => { requireSignedOut(); return removeControlPlane(id); });
  ipcMain.handle("studio:session", () => publicSession(currentSession()));

  ipcMain.handle("studio:signIn", async () => {
    startingSignIn = true;
    try {
      pending = await startDeviceAuth();
      return { userCode: pending.userCode, verificationUri: pending.verificationUri };
    } finally { startingSignIn = false; }
  });

  ipcMain.handle("studio:cancelSignIn", () => {
    cancelDeviceAuth();
    pending = null;
  });

  ipcMain.handle("studio:awaitSignIn", async () => {
    if (!pending) throw new Error("No sign-in in progress.");
    try {
      return publicSession(await pollDeviceAuth(pending));
    } finally {
      pending = null;
    }
  });

  ipcMain.handle("studio:signOut", () => {
    pending = null;
    cancelDeviceAuth();
    signOut();
    // A new account must never inherit old in-flight streams or callbacks.
    app.emit("tbd:reset-session");
  });

  ipcMain.handle("studio:listAgents", (_event, opts?: { refreshSession?: boolean }) =>
    listAgents({ refreshSession: opts?.refreshSession === true }));
  ipcMain.handle(
    "studio:saveAgentProfile",
    (_e, input: Parameters<typeof saveAgentProfile>[0]) => saveAgentProfile(input),
  );

  // F4-1: every agent-bound handler takes an agent id, never a URL. Main
  // resolves the address from Portal's records, so web content cannot make
  // this app send a credential somewhere of its choosing.
  ipcMain.handle("studio:agentInfo", (_e, agentId: string) => agentInfo(agentId));

  ipcMain.handle("studio:agentHealth", (_e, agentId: string) => agentHealth(agentId));

  ipcMain.handle(
    "studio:localAnswer",
    (_e, input: { id: string; allow: boolean; remember: boolean }) => {
      answerAsk(input.id, input.allow, input.remember);
    },
  );

  ipcMain.handle(
    "studio:replaySession",
    (_e, input: { agentId: string; sessionId: string; limit?: number }) =>
      replaySession({ agentId: input?.agentId, sessionId: input?.sessionId, limit: input?.limit }),
  );

  ipcMain.handle("studio:loadState", (_e, name: string) => loadState(scopedStateName(name), null));
  ipcMain.handle("studio:saveState", (_e, input: { name: string; value: unknown }) => {
    saveState(scopedStateName(input.name), input.value);
  });
  ipcMain.handle("studio:pickFolder", () => pickFolder());










  ipcMain.handle("studio:openExternal", (_e, url: string) => shell.openExternal(url));

  // Files the agent handed back. The renderer passes a location the USER
  // clicked; none of these take an instruction from the model.
  ipcMain.handle("studio:fileExists", (_e, path: string) => localFileExists(path));

  ipcMain.handle("studio:openLocalFile", (_e, path: string) => openLocalFile(path));
  ipcMain.handle("studio:revealLocalFile", (_e, path: string) => revealLocalFile(path));
  ipcMain.handle(
    "studio:saveRemoteFile",
    (_e, input: { url: string; suggestedName: string }) => saveRemoteFile(input),
  );
  ipcMain.handle(
    "studio:openRemoteFile",
    (_e, input: { url: string; suggestedName: string }) => openRemoteFile(input),
  );



  ipcMain.handle(
    "studio:cancelTurn",
    (_e, input: { agentId: string; sessionId: string; turnId?: string }) =>
      cancelTurn({ agentId: input?.agentId, sessionId: input?.sessionId, turnId: input?.turnId }),
  );

  ipcMain.handle(
    "studio:resetSession",
    (_e, input: { agentId: string; sessionId?: string }) =>
      resetSession({ agentId: input?.agentId, sessionId: input?.sessionId }),
  );

  /** One watcher per stream id; stopping one aborts its follower. */
  const watchers = new Map<string, AbortController>();
  ipcMain.handle(
    "studio:watch",
    (e, input: { agentId: string; sessionId: string; streamIndex: number; streamId: string }) => {
      const sender: WebContents = e.sender;
      console.log(`[watch] asked for ${input.streamId} on ${input.sessionId.slice(0, 18)} from ${input.streamIndex}`);
      watchers.get(input.streamId)?.abort();
      const ctrl = new AbortController();
      watchers.set(input.streamId, ctrl);
      const send = (channel: string, payload: unknown): void => {
        if (!sender.isDestroyed() && !ctrl.signal.aborted) sender.send(channel, payload);
      };
      // A watcher outlives its page unless something ends it. The renderer only
      // sends unwatch when it switches agent — never when the window closes or
      // the page reloads — and stream ids are minted fresh per watch, so the old
      // one can never be displaced by a re-watch. Left alone, `follow: true`
      // reconnects to the agent forever with nobody listening. Tie it to the
      // page that asked for it.
      const drop = (): void => {
        if (watchers.get(input.streamId) === ctrl) watchers.delete(input.streamId);
        ctrl.abort();
      };
      sender.once("destroyed", drop);
      sender.once("did-start-loading", drop);

      void watchSession({
        agentId: input.agentId,
        sessionId: input.sessionId,
        startIndex: input.streamIndex,
        signal: ctrl.signal,
        onDelta: (text) => send("studio:delta", { streamId: input.streamId, text }),
        onReset: () => send("studio:reset", { streamId: input.streamId }),
        onActivity: (label) => send("studio:activity", { streamId: input.streamId, label }),
        onCursor: (index) => send("studio:cursor", { streamId: input.streamId, index }),
        onPeer: (event) => send("studio:peer", { streamId: input.streamId, event }),
        onAuthorization: (event) => send("studio:authorization", { streamId: input.streamId, event }),
        onQuestion: (request) => send("studio:question", { streamId: input.streamId, request }),
        onLive: (kind) => send("studio:live", { streamId: input.streamId, kind }),
      })
        .catch((error: unknown) => {
          console.log("[watch] stream ended with an error");
          send("studio:live", { streamId: input.streamId, kind: "ended" });
        })
        .finally(() => {
          if (watchers.get(input.streamId) === ctrl) watchers.delete(input.streamId);
          // The stream is over on its own terms; stop holding listeners on the page.
          if (!sender.isDestroyed()) {
            sender.off("destroyed", drop);
            sender.off("did-start-loading", drop);
          }
        });
    },
  );
  /**
   * A native notification, when the person is elsewhere.
   *
   * The renderer decides whether one is warranted — it knows whether the
   * window is focused and which thread is open — and main only shows it.
   * Clicking brings the window forward and opens the agent it came from.
   */
  ipcMain.handle("studio:notify", (e, input: { title: string; body: string; agentId: string }) => {
    console.log(`[notify] main: supported=${Notification.isSupported()}`);
    if (!Notification.isSupported()) return;
    const sender: WebContents = e.sender;
    const n = new Notification({ title: input.title, body: input.body });
    n.on("show", () => console.log("[notify] main: shown"));
    n.on("failed", () => console.log("[notify] main: failed"));
    n.on("click", () => {
      const win = BrowserWindow.fromWebContents(sender);
      if (win) {
        if (win.isMinimized()) win.restore();
        win.show();
        win.focus();
      }
      if (!sender.isDestroyed()) sender.send("studio:open-agent", { agentId: input.agentId });
    });
    n.show();
  });
  ipcMain.handle("studio:unwatch", (_e, streamId: string) => {
    watchers.get(streamId)?.abort();
    watchers.delete(streamId);
  });

  ipcMain.handle(
    "studio:send",
    (
      e,
      input: {
        agentId: string;
        text: string;
        attachments?: Attachment[];
        sessionId?: string;
        streamIndex?: number;
        inputResponses?: { requestId: string; optionId?: string; text?: string }[];
        clientContext?: Record<string, unknown>;
        streamId: string;
      },
    ) => {
      const sender: WebContents = e.sender;
      return sendTurn({
        // Named fields, not a spread: an extra `url` from web content must not
        // ride along into the main process.
        agentId: input.agentId,
        text: input.text,
        attachments: input.attachments,
        sessionId: input.sessionId,
        streamIndex: input.streamIndex,
        inputResponses: input.inputResponses,
        clientContext: input.clientContext,
        onDelta: (text) => {
          // The window can go away mid-turn; writing to a destroyed sender throws.
          if (!sender.isDestroyed()) sender.send("studio:delta", { streamId: input.streamId, text });
        },
        onReset: () => {
          if (!sender.isDestroyed()) sender.send("studio:reset", { streamId: input.streamId });
        },
        onActivity: (label) => {
          if (!sender.isDestroyed()) {
            sender.send("studio:activity", { streamId: input.streamId, label });
          }
        },
        onCursor: (index) => {
          if (!sender.isDestroyed()) {
            sender.send("studio:cursor", { streamId: input.streamId, index });
          }
        },
        onTurn: (turn) => {
          if (!sender.isDestroyed()) {
            sender.send("studio:turn", { streamId: input.streamId, ...turn });
          }
        },
        onPeer: (event) => {
          if (!sender.isDestroyed()) {
            sender.send('studio:peer', { streamId: input.streamId, event });
          }
        },
        onAuthorization: (event) => {
          if (!sender.isDestroyed()) {
            sender.send("studio:authorization", { streamId: input.streamId, event });
          }
        },
        onQuestion: (request) => {
          // Logged because a question that never reaches the window is
          // indistinguishable from an agent that said nothing.
          console.log(
            `[question→ui] ${request.requestId} destroyed=${sender.isDestroyed()} stream=${input.streamId}`,
          );
          if (!sender.isDestroyed()) {
            sender.send("studio:question", { streamId: input.streamId, request });
          }
        },
      });
    },
  );



}
