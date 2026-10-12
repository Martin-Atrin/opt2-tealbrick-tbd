import { portalWorkspaces, selectPortalWorkspace, scopedStateName, selectedPortalWorkspace } from "./portalWorkspaces";
import { app, BrowserWindow, Notification, ipcMain, nativeCall, shell, type WebContents } from "../tbd/host";
import { activateControlPlane, addControlPlane, controlPlanes, removeControlPlane } from "./controlPlanes";
import { assertPlaneSwitchAllowed } from "./controlPlaneProfiles";
import type { Attachment, RemoteAgent } from "../shared/ipc";
import { loadState, pickFolder, saveState } from "./store";
import { localFileExists, openLocalFile, openRemoteFile, revealLocalFile, saveRemoteFile } from "./deliveredFile";
import { answerAsk } from "./asks";
import { addAgentFolder, agentFolders, agentWorkspace, ensurePerson, getServices, removeAgentFolder, resetServices } from "./services";
import { dialog } from "../tbd/host";
import { publicPersonSession } from "./portal";
import { DEFAULT_AGENT_ID } from "./defaultAgent";
import { buildMessage } from "../shared/message";
import type { DeviceStart } from "@opt2-tealbrick/spec/routes";
import { checkForUpdate } from "./updates";

/**
 * The renderer's bridge into the helper. TBD Chat talks to exactly one agent:
 * TBD's own default agent (C24). The person signs in with the owner device
 * flow (K3); the agent connects with its own key (K4). Neither credential is
 * ever returned to web content.
 */

let pendingSignIn: DeviceStart | null = null;
let startingSignIn = false;

/** Whether the agent has a model route; the note the UI shows when it does not. */
async function agentReadiness(): Promise<{ ready: boolean; note?: string }> {
  try {
    await nativeCall("agentModelStatus");
    const connection = getServices().agentIdentity.connection();
    return connection
      ? { ready: true }
      : { ready: true, note: "TBD's agent works with your timeline and transcripts. Connect it to your workspace in its Settings to use Teal Brick apps." };
  } catch (error) {
    return { ready: false, note: error instanceof Error ? error.message : "Choose a model for TBD's agent in Settings → Models." };
  }
}

async function defaultAgentRow(): Promise<RemoteAgent> {
  const status = await agentReadiness();
  return {
    id: DEFAULT_AGENT_ID,
    name: "TBD",
    runtime: "tbd-default",
    url: "local://tbd",
    accessMode: "private",
    audience: null,
    hasUrl: true,
    reachable: status.ready,
    daemonLabel: null,
    connection: status.note ? { mode: "withheld", note: status.note } : undefined,
    peers: [],
    profile: null,
  };
}

function requireDefaultAgent(agentId: unknown): void {
  if (agentId !== DEFAULT_AGENT_ID) throw new Error("TBD Chat talks only to TBD's own agent.");
}

/** Handlers that use the person session load it first (lazily, once; may ask for user presence). */
function withPerson<A extends unknown[], R>(fn: (...args: A) => R | Promise<R>): (...args: A) => Promise<R> {
  return async (...args: A) => { await ensurePerson(); return fn(...args); };
}

export function registerIpc(): void {
  const signedIn = () => Boolean(getServices().portal.session());
  ipcMain.handle("studio:portalWorkspaces", withPerson(() => portalWorkspaces()));
  ipcMain.handle("studio:selectPortalWorkspace", withPerson((_e: unknown, id: string) => selectPortalWorkspace(id)));
  const requireSignedOut = (): void => assertPlaneSwitchAllowed(signedIn(), startingSignIn || Boolean(pendingSignIn));
  ipcMain.handle("studio:controlPlanes", () => controlPlanes());
  ipcMain.handle("studio:activateControlPlane", async (_e, id: string) => { requireSignedOut(); activateControlPlane(id); resetServices(); });
  ipcMain.handle("studio:addControlPlane", async (_e, input: { name: string; issuer: string }) => { requireSignedOut(); addControlPlane(input); resetServices(); });
  ipcMain.handle("studio:removeControlPlane", (_e, id: string) => { requireSignedOut(); return removeControlPlane(id); });
  ipcMain.handle("studio:session", withPerson(async () => {
    const s = publicPersonSession(getServices().portal.session());
    return s ? { expiresAt: s.expiresAt, email: s.email ?? undefined } : null;
  }));

  // Person sign-in: device flow client_id=tbd, scope=owner. The approval page opens in the system browser.
  ipcMain.handle("studio:signIn", withPerson(async () => {
    startingSignIn = true;
    try {
      pendingSignIn = await getServices().portal.startSignIn();
      void shell.openExternal(pendingSignIn.verification_uri_complete);
      return { userCode: pendingSignIn.user_code, verificationUri: pendingSignIn.verification_uri };
    } finally { startingSignIn = false; }
  }));
  ipcMain.handle("studio:cancelSignIn", () => { getServices().portal.cancelSignIn(); pendingSignIn = null; });
  ipcMain.handle("studio:awaitSignIn", withPerson(async () => {
    if (!pendingSignIn) throw new Error("No sign-in in progress.");
    try {
      const s = await getServices().portal.awaitSignIn(pendingSignIn);
      return { expiresAt: s.expiresAt, email: s.email ?? undefined };
    } finally { pendingSignIn = null; }
  }));
  ipcMain.handle("studio:signOut", withPerson(async () => {
    pendingSignIn = null;
    await getServices().portal.signOut();
    resetServices();
    app.emit("tbd:reset-session");
  }));

  // The agent directory is TBD's own agent only.
  ipcMain.handle("studio:listAgents", withPerson(async () => {
    if (!signedIn()) throw new Error("Not signed in.");
    return [await defaultAgentRow()];
  }));
  ipcMain.handle("studio:saveAgentProfile", () => undefined);
  ipcMain.handle("studio:agentInfo", (_e, agentId: string) => {
    requireDefaultAgent(agentId);
    return {
      name: "TBD",
      harness: "tbd-default",
      protocol: "tealbrick-native",
      native: true,
      capabilities: ["chat", "resume", "cancel", "timeline", "transcripts"],
      tools: [
        { name: "Companion timeline", description: "Your screen-activity timeline on this Mac." },
        { name: "Listening", description: "Your local transcripts, meetings and dictations." },
      ],
    };
  });
  ipcMain.handle("studio:agentHealth", async (_e, agentId: string) => { requireDefaultAgent(agentId); return (await agentReadiness()).ready; });
  ipcMain.handle("studio:replaySession", () => null);

  // TBD's agent identity (key connection, K4 in the Keychain).
  ipcMain.handle("studio:agentConnection", () => {
    const c = getServices().agentIdentity.connection();
    return c ? { connected: true, workspaceId: c.workspaceId, agentId: c.agentId } : { connected: false };
  });
  ipcMain.handle("studio:agentConnect", withPerson(async () => {
    if (!signedIn()) throw new Error("Sign in first.");
    const start = await getServices().agentIdentity.start();
    void shell.openExternal(start.verification_uri_complete);
    return { userCode: start.user_code, verificationUri: start.verification_uri };
  }));
  ipcMain.handle("studio:awaitAgentConnect", async () => {
    const c = await getServices().agentIdentity.await();
    getServices().agent.stop(); // restart with the relay on the next turn
    return { connected: true, workspaceId: c.workspaceId, agentId: c.agentId };
  });
  ipcMain.handle("studio:cancelAgentConnect", () => getServices().agentIdentity.cancel());
  ipcMain.handle("studio:agentDisconnect", async () => { await getServices().agentIdentity.disconnect(); getServices().agent.stop(); });

  // SEC-04: the agent's working folder and the folders the person lets it read.
  ipcMain.handle("studio:agentFolders", () => ({ workspace: agentWorkspace(), folders: agentFolders() }));
  ipcMain.handle("studio:addAgentFolder", async () => {
    const picked = (await dialog.showOpenDialog({ properties: ["openDirectory"] })) as { canceled?: boolean; filePaths?: string[] };
    if (picked?.canceled || !picked?.filePaths?.[0]) return { workspace: agentWorkspace(), folders: agentFolders() };
    return { workspace: agentWorkspace(), folders: addAgentFolder(picked.filePaths[0]) };
  });
  ipcMain.handle("studio:removeAgentFolder", (_e, path: string) => ({ workspace: agentWorkspace(), folders: removeAgentFolder(String(path)) }));
  ipcMain.handle("studio:openAgentWorkspace", () => shell.openPath(agentWorkspace()));

  // Approvals: counts only (S2/C24); the hold pages open in the system browser.
  ipcMain.handle("studio:pendingHolds", withPerson(async () => {
    try { return await getServices().portal.pendingHolds(selectedPortalWorkspace()); } catch { return []; }
  }));

  // Update feed for the native updater: verified release index → newest TBD desktop release, or null.
  ipcMain.handle("studio:checkUpdate", (_e, input: { version: string; os: string; channel?: "stable" | "dev" }) =>
    checkForUpdate({ version: String(input?.version ?? "0"), os: String(input?.os ?? "14.0"), channel: input?.channel === "dev" ? "dev" : "stable" }));

  ipcMain.handle("studio:localAnswer", (_e, input: { id: string; allow: boolean; remember: boolean }) => {
    answerAsk(input.id, input.allow, input.remember);
  });

  ipcMain.handle("studio:loadState", (_e, name: string) => loadState(scopedStateName(name), null));
  ipcMain.handle("studio:saveState", (_e, input: { name: string; value: unknown }) => {
    saveState(scopedStateName(input.name), input.value);
  });
  ipcMain.handle("studio:pickFolder", () => pickFolder());
  ipcMain.handle("studio:openExternal", (_e, url: string) => shell.openExternal(url));

  // Files the agent handed back. The renderer passes a location the USER clicked.
  ipcMain.handle("studio:fileExists", (_e, path: string) => localFileExists(path));
  ipcMain.handle("studio:openLocalFile", (_e, path: string) => openLocalFile(path));
  ipcMain.handle("studio:revealLocalFile", (_e, path: string) => revealLocalFile(path));
  ipcMain.handle("studio:saveRemoteFile", (_e, input: { url: string; suggestedName: string }) => saveRemoteFile(input));
  ipcMain.handle("studio:openRemoteFile", (_e, input: { url: string; suggestedName: string }) => openRemoteFile(input));

  /** Live turn ids per stream, so Stop reaches the right turn. */
  const liveTurns = new Map<string, string>();
  ipcMain.handle("studio:cancelTurn", (_e, input: { agentId: string; turnId?: string }) => {
    requireDefaultAgent(input?.agentId);
    getServices().agent.cancel(input?.turnId);
    return "cancelled";
  });
  ipcMain.handle("studio:resetSession", (_e, input: { agentId: string }) => { requireDefaultAgent(input?.agentId); });
  // Only TBD's own turns exist; there is no remote session to follow.
  ipcMain.handle("studio:watch", () => undefined);
  ipcMain.handle("studio:unwatch", () => undefined);

  ipcMain.handle("studio:notify", (e, input: { title: string; body: string; agentId: string }) => {
    if (!Notification.isSupported()) return;
    const sender: WebContents = e.sender;
    const n = new Notification({ title: input.title, body: input.body });
    n.on("click", () => {
      const win = BrowserWindow.fromWebContents(sender);
      if (win) { if (win.isMinimized()) win.restore(); win.show(); win.focus(); }
      if (!sender.isDestroyed()) sender.send("studio:open-agent", { agentId: input.agentId });
    });
    n.show();
  });

  ipcMain.handle(
    "studio:send",
    async (e, input: { agentId: string; text: string; attachments?: Attachment[]; sessionId?: string; clientContext?: Record<string, unknown>; streamId: string }) => {
      requireDefaultAgent(input.agentId);
      const sender: WebContents = e.sender;
      const emit = (channel: string, payload: Record<string, unknown>) => {
        if (!sender.isDestroyed()) sender.send(channel, { streamId: input.streamId, ...payload });
      };
      const folder = typeof input.clientContext?.workingFolder === "string" ? `\n\n(Working folder: ${input.clientContext.workingFolder})` : "";
      const text = buildMessage(input.text, input.attachments ?? []) + folder;
      const result = await getServices().agent.sendTurn({
        text,
        sessionId: input.sessionId,
        onDelta: (t) => emit("studio:delta", { text: t }),
        onReset: () => emit("studio:reset", {}),
        onActivity: (label) => emit("studio:activity", { label }),
        onTurn: (turn) => { if (turn.turnId) liveTurns.set(input.streamId, turn.turnId); emit("studio:turn", turn); },
      });
      liveTurns.delete(input.streamId);
      return { reply: result.reply, sessionId: result.sessionId, streamIndex: 0, askedQuestion: false };
    },
  );
}
