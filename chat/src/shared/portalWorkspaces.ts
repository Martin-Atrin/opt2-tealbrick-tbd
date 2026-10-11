export interface PortalWorkspace { id: string; name: string }
export interface WorkspaceDirectory { accountId: string; organizationId: string; workspaces: PortalWorkspace[] }
export interface WorkspaceSelection extends WorkspaceDirectory { selectedId: string | null }

