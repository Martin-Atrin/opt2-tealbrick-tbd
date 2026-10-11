/** Presentation only; never an authorization or storage scope. */
export function workspaceFooterLabel(workspaces: readonly { id: string; name: string }[], selectedId: string | null): string {
  return workspaces.find(workspace => workspace.id === selectedId)?.name ?? "No workspace selected";
}
