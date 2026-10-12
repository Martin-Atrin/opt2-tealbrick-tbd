import test from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
import { createRequire } from 'node:module';
import vm from 'node:vm';
const bundle=await build({entryPoints:['src/renderer/src/lib/store.ts'],bundle:true,platform:'node',format:'cjs',packages:'external',tsconfig:'tsconfig.web.json',write:false});
function fixture(selectedId=null) {
  const calls=[];
  const directory={accountId:'a',organizationId:'o',selectedId,workspaces:[{id:'one',name:'One'},{id:'two',name:'Two'}]};
  const api=new Proxy({
    controlPlanes:async()=>({activeId:'hosted',profiles:[{id:'hosted',issuer:'https://portal.example'}]}),
    session:async()=>({email:'fixture@example.test'}),portalWorkspaces:async()=>directory,
    listAgents:async()=>{calls.push('agents');return [{id:'agent',name:'Eve',url:null}];},
    
    loadState:async()=>{calls.push('restore');return null;},
    saveState:async()=>{},selectPortalWorkspace:async(id)=>{directory.selectedId=id;},
  },{get:(target,key)=>target[key]??(()=>Promise.resolve(null))});
  const module={exports:{}};
  vm.runInNewContext(bundle.outputFiles[0].text,{module,exports:module.exports,require:createRequire(import.meta.url),console,Error,window:{studio:api,addEventListener:()=>{}},document:{addEventListener:()=>{},visibilityState:'hidden',hasFocus:()=>false},setInterval:()=>0,clearInterval:()=>{},setTimeout,clearTimeout,AbortController});
  return {store:module.exports.useStore,api,calls,directory};
}
test('post-login chooser gates history and agents until a workspace is selected',async()=>{
  const f=fixture();await f.store.getState().bootstrap();
  assert.equal(f.store.getState().authState,'signed-in');
  assert.equal(f.store.getState().portalWorkspaceId,null);
  assert.deepEqual(f.calls,[]);
  await f.store.getState().refreshAgents();assert.deepEqual(f.calls,[]);
});
test('selected workspace restores history then loads agents; switch clears immediately',async()=>{
  const f=fixture('one');await f.store.getState().bootstrap();
  assert.equal(f.store.getState().portalWorkspaceId,'one');assert.ok(f.calls.indexOf('restore')<f.calls.indexOf('agents'));
  let finish: (v?: unknown) => void = () => {};f.api.selectPortalWorkspace=()=>new Promise(r=>{finish=r});
  const switching=f.store.getState().switchPortalWorkspace('two');
  assert.equal(f.store.getState().agents.length,0);
  assert.equal(Object.keys(f.store.getState().conversations).length,0);assert.equal(f.store.getState().portalWorkspaceId,null);
  f.directory.selectedId='two';finish();await switching;
  assert.equal(f.store.getState().portalWorkspaceId,'two');
  assert.equal(f.store.getState().workspaceLoading,false);
});
test('late agent result from previous workspace is discarded',async()=>{
  const f=fixture('one');await f.store.getState().bootstrap();
  let complete: (v: unknown) => void = () => {};let reads=0;f.api.listAgents=()=>++reads===1?new Promise(r=>{complete=r}):Promise.resolve([{id:'new',name:'New',url:null}]);
  const pending=f.store.getState().refreshAgents();
  await f.store.getState().switchPortalWorkspace('two');complete([{id:'old',name:'Old'}]);await pending;
  assert.deepEqual(f.store.getState().agents.map(a=>a.id),['new']);
});
test('workspace API failure stays signed in but blocks discovery; failed refresh clears stale agents',async()=>{
  const f=fixture('one');f.api.portalWorkspaces=async()=>{throw Error('API missing')};await f.store.getState().bootstrap();
  assert.equal(f.store.getState().authState,'signed-in');assert.equal(f.store.getState().workspaceError,'API missing');assert.deepEqual(f.calls,[]);
  const g=fixture('one');await g.store.getState().bootstrap();g.api.listAgents=async()=>{throw Error('Access revoked')};await g.store.getState().refreshAgents();assert.equal(g.store.getState().agents.length,0);
});
