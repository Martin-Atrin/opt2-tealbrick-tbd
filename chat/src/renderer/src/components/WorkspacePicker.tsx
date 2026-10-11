import { useStore } from '../lib/store';

export function WorkspacePicker() {
  const { portalWorkspaces, workspaceLoading, workspaceError, switchPortalWorkspace, loadPortalWorkspaces, issuer, signOut } = useStore();
  return <main className="workspace-home">
    <header className="workspace-home__masthead">
      <div className="workspace-home__brand"><img src="./brand/teal-brick-colour.png" width="28" height="28" alt="" />teal brick<span>studio</span></div>
      <button onClick={() => void signOut()}>Sign out</button>
    </header>
    <div className="workspace-home__content">
      <header className="workspace-home__heading">
        <div><span className="workspace-home__eyebrow">YOUR WORKING SYSTEMS</span>
          <h1>Workspaces</h1>
          <p>Choose where you want to work. Your agents and conversations are waiting inside.</p>
        </div>
        <button className="workspace-home__portal" onClick={() => void window.studio.openExternal(`${issuer}/portal`)}>Open portal ↗</button>
      </header>
      {workspaceLoading ? <div className="workspace-home__notice" role="status">Opening your workspaces…</div> : workspaceError ?
        <div className="workspace-home__notice" role="alert"><h2>We couldn’t load your workspaces.</h2><p>{workspaceError}</p><button className="btn" onClick={() => void loadPortalWorkspaces()}>Try again</button></div> :
        <div className="workspace-home__grid">{portalWorkspaces.length ? portalWorkspaces.map((w, index) =>
          <button className="workspace-home__card" key={w.id} onClick={() => void switchPortalWorkspace(w.id)}>
            <span className="workspace-home__eyebrow">WORKSPACE / {String(index + 1).padStart(2, '0')}</span>
            <h2>{w.name}</h2><span className="workspace-home__open">Open workspace <span aria-hidden="true">→</span></span>
          </button>) : <div className="workspace-home__notice"><h2>A space for your first system.</h2><p>Create a workspace in the portal, then come back here to connect.</p></div>}
        </div>}
      <footer className="workspace-home__footer"><span>You can switch workspaces from your account menu.</span><button disabled={workspaceLoading} onClick={() => void loadPortalWorkspaces()}>Refresh workspaces ↻</button></footer>
    </div>
  </main>;
}
