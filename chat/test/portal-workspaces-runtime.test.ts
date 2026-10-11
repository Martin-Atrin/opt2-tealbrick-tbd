import test from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
import { createRequire } from 'node:module';
import vm from 'node:vm';

async function fixture() {
  const saves = new Map(), events: string[] = [];
  const state: any = { directory: { accountId: 'a', organizationId: 'a', workspaces: [{ id: 'one', name: 'One' }, { id: 'two', name: 'Two' }] }, fail: null as string | null };
  const result = await build({ entryPoints: ['src/main/portalWorkspaces.ts'], bundle: true, platform: 'node', format: 'cjs', write: false, plugins: [{ name: 'fixture', setup(b) {
    b.onResolve({ filter: /^(\.\.\/tbd\/host|\.\/store|\.\/services|\.\/controlPlanes)$/ }, (args) => ({ path: args.path, namespace: 'fixture' }));
    b.onLoad({ filter: /.*/, namespace: 'fixture' }, (args) => ({ loader: 'js', contents:
      args.path === '../tbd/host' ? `export const app={emit:(event)=>events.push(event)}` :
      args.path === './store' ? `export const loadState=(n,f)=>saves.get(n)??f;export const saveState=(n,v)=>saves.set(n,v);` :
      args.path === './controlPlanes' ? `export const currentControlPlane=()=>({issuer:'https://portal.example'})` :
      `export const getServices=()=>{throw Error('tests inject the loader')}` }));
  } }] });
  const module: any = { exports: {} };
  vm.runInNewContext(result.outputFiles[0].text, { module, exports: module.exports, require: createRequire(import.meta.url), saves, events });
  const loader = async () => { if (state.fail) throw new Error(state.fail); return structuredClone(state.directory); };
  return { api: module.exports, state, saves, events, loader };
}

test('selection is server-validated, remembered, isolated per account and requests only a scoped reset', async () => {
  const f = await fixture();
  assert.equal((await f.api.portalWorkspaces(f.loader)).selectedId, null);
  assert.throws(() => f.api.selectedPortalWorkspace());
  await f.api.selectPortalWorkspace('two', f.loader);
  assert.deepEqual(f.events, ['tbd:reset-session']);
  assert.equal((await f.api.portalWorkspaces(f.loader)).selectedId, 'two');
  const first = f.api.scopedStateName('conversations.json');
  f.state.directory = { ...f.state.directory, accountId: 'other', organizationId: 'other' };
  assert.equal((await f.api.portalWorkspaces(f.loader)).selectedId, null);
  assert.throws(() => f.api.scopedStateName('conversations.json'));
  f.state.directory.workspaces = [{ id: 'two', name: 'Two' }];
  await f.api.portalWorkspaces(f.loader);
  assert.notEqual(f.api.scopedStateName('conversations.json'), first);
});

test('deleted selection and failed loads do not retain an authorized workspace', async () => {
  const f = await fixture();
  await f.api.portalWorkspaces(f.loader);
  f.state.directory.workspaces = [];
  await assert.rejects(f.api.selectPortalWorkspace('one', f.loader), /no longer available/);
  assert.equal(f.events.length, 0);
  f.state.directory.workspaces = [{ id: 'one', name: 'One' }];
  assert.equal((await f.api.portalWorkspaces(f.loader)).selectedId, 'one');
  f.state.fail = 'Not signed in.';
  await assert.rejects(f.api.portalWorkspaces(f.loader), /Not signed in/);
  assert.throws(() => f.api.selectedPortalWorkspace());
});
