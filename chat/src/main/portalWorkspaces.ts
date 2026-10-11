import { app } from 'electron';
import { activeSession, authHeaders, issuer } from './controlPlane';
import { loadState, saveState } from './store';
import { choosePortalWorkspace, parseWorkspaceDirectory, workspaceAccountKey, workspaceStateName, type WorkspaceSelection } from './workspaceSelection';
let current: WorkspaceSelection | null = null;
let accountKey: string | null = null;
export function resetPortalWorkspace(): void { current = null; accountKey = null; }
export async function portalWorkspaces(): Promise<WorkspaceSelection> {
  resetPortalWorkspace();
  const session = await activeSession();
  if (!session) { resetPortalWorkspace(); throw new Error('Not signed in.'); }
  const response = await fetch(`${issuer()}/api/me/workspaces`, { headers: authHeaders(session), signal: AbortSignal.timeout(20000) });
  if (!response.ok) { resetPortalWorkspace(); throw new Error(`Could not load workspaces (HTTP ${response.status}). This portal needs the desktop workspace API.`); }
  const directory = parseWorkspaceDirectory(await response.json());
  accountKey = workspaceAccountKey(issuer(), directory);
  const saved = loadState<Record<string, string>>('portal-workspaces.json', {});
  const selectedId = choosePortalWorkspace(directory.workspaces, saved[accountKey]);
  if (selectedId && saved[accountKey] !== selectedId) saveState("portal-workspaces.json", { ...saved, [accountKey]: selectedId });
  current = { ...directory, selectedId };
  return current;
}
export function selectedPortalWorkspace(): string {
  if (!current?.selectedId) throw new Error('Select a workspace first.');
  return current.selectedId;
}
export function scopedStateName(name: string): string {
  if (!accountKey) throw new Error('Select a workspace first.');
  return workspaceStateName(accountKey, selectedPortalWorkspace(), name);
}
export async function selectPortalWorkspace(id: string): Promise<void> {
  // Revalidate against server membership, including deletion since the chooser loaded.
  const directory = await portalWorkspaces();
  if (!directory.workspaces.some(w => w.id === id) || !accountKey) throw new Error('This workspace is no longer available.');
  const saved = loadState<Record<string, string>>('portal-workspaces.json', {});
  saveState('portal-workspaces.json', { ...saved, [accountKey]: id });
  // End old streams and callbacks before another workspace can read/write state.
  app.emit("tbd:reset-session");
}
