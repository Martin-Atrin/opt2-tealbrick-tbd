import test from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
import { createRequire } from 'node:module';
import vm from 'node:vm';

async function fixture() {
  const calls=[], saves=new Map(), events=[];
  const state={ session:{token:'fixture'}, directory:{accountId:'a',organizationId:'o',workspaces:[{id:'one',name:'One'},{id:'two',name:'Two'}]},status:200 };
  const result=await build({entryPoints:['src/main/portalWorkspaces.ts'],bundle:true,platform:'node',format:'cjs',write:false,plugins:[{name:'fixture',setup(b){
    b.onResolve({filter:/^(\.\.\/tbd\/host|\.\/controlPlane|\.\/store)$/},args=>({path:args.path,namespace:'fixture'}));
    b.onLoad({filter:/.*/,namespace:'fixture'},args=>({contents:args.path==='../tbd/host'?`export const app={emit:(event)=>events.push(event),relaunch:()=>{throw Error('Must not relaunch')},quit:()=>{throw Error('Must not quit')}}`:args.path==='./store'?`export const loadState=(n,f)=>saves.get(n)??f;export const saveState=(n,v)=>saves.set(n,v);`:`export const issuer=()=> 'https://portal.example';export const activeSession=async()=>state.session;export const authHeaders=s=>({authorization:'Bearer '+s.token});`,loader:'js'}));
  }}]});
  const module={exports:{}};
  vm.runInNewContext(result.outputFiles[0].text,{module,exports:module.exports,require:createRequire(import.meta.url),state,saves,events,AbortSignal,fetch:async(url,init)=>{calls.push({url,init});return {ok:state.status===200,status:state.status,json:async()=>state.directory};}});
  return {api:module.exports,state,calls,saves,events};
}
test('native selection is server-validated, remembered, isolated and requests only a scoped transport reset',async()=>{
  const f=await fixture();
  assert.equal((await f.api.portalWorkspaces()).selectedId,null);
  assert.throws(()=>f.api.selectedPortalWorkspace());
  await f.api.selectPortalWorkspace('two');
  assert.deepEqual(f.events,['tbd:reset-session']);
  assert.equal((await f.api.portalWorkspaces()).selectedId,'two');
  const first=f.api.scopedStateName('conversations.json');
  f.state.directory={...f.state.directory,accountId:'other'};
  assert.equal((await f.api.portalWorkspaces()).selectedId,null);
  assert.throws(()=>f.api.scopedStateName('conversations.json'));
  f.state.directory.workspaces=[{id:'two',name:'Two'}];
  await f.api.portalWorkspaces();
  assert.notEqual(f.api.scopedStateName('conversations.json'),first);
  assert.ok(f.calls.every(c=>c.url==='https://portal.example/api/me/workspaces'));
});
test('deleted selection, unsupported endpoint and sign-out do not retain an authorized workspace',async()=>{
  const f=await fixture();await f.api.portalWorkspaces();
  f.state.directory.workspaces=[];
  await assert.rejects(f.api.selectPortalWorkspace('one'),/no longer available/);
  assert.equal(f.events.length,0);
  f.state.directory.workspaces=[{id:'one',name:'One'}];
  assert.equal((await f.api.portalWorkspaces()).selectedId,'one');
  f.state.status=404;await assert.rejects(f.api.portalWorkspaces(),/workspace API/);
  assert.throws(()=>f.api.selectedPortalWorkspace());
  f.state.session=null;await assert.rejects(f.api.portalWorkspaces(),/Not signed in/);
});
