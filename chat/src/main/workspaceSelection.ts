import { createHash } from 'node:crypto';

import type { PortalWorkspace, WorkspaceDirectory, WorkspaceSelection } from "../shared/portalWorkspaces";
export type { PortalWorkspace, WorkspaceDirectory, WorkspaceSelection };

/** Storage partitioning, not authorization. The server supplies account and workspace identity. */
export function workspaceAccountKey(issuer: string, directory: WorkspaceDirectory): string {
  return createHash('sha256').update(JSON.stringify([issuer, directory.organizationId, directory.accountId])).digest('hex');
}
export function choosePortalWorkspace(workspaces: PortalWorkspace[], remembered?: string): string | null {
  if (remembered && workspaces.some(w => w.id === remembered)) return remembered;
  return workspaces.length === 1 ? workspaces[0]!.id : null;
}
export function parseWorkspaceDirectory(value: unknown): WorkspaceDirectory {
  const d = value as WorkspaceDirectory;
  if (!d || typeof d.accountId !== 'string' || !d.accountId || typeof d.organizationId !== 'string' || !d.organizationId || !Array.isArray(d.workspaces) || d.workspaces.some(w => !w || typeof w.id !== 'string' || !w.id || typeof w.name !== 'string') || new Set(d.workspaces.map(w => w.id)).size !== d.workspaces.length) throw new Error('The portal returned an invalid workspace directory.');
  return { accountId: d.accountId, organizationId: d.organizationId, workspaces: d.workspaces.map(w => ({ id: w.id, name: w.name })) };
}
export function workspaceStateName(accountKey: string, workspaceId: string, name: string): string {
  if (!['conversations.json', 'workspaces.json'].includes(name)) throw new Error('Unknown workspace state file.');
  const key = createHash('sha256').update(JSON.stringify([accountKey, workspaceId])).digest('hex');
  return `workspace-${key}-${name}`;
}
