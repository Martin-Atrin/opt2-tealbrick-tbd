import test from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
import { createRequire } from 'node:module';
import vm from 'node:vm';
import { webcrypto } from 'node:crypto';
const bundle=await build({entryPoints:['src/renderer/src/lib/store.ts'],bundle:true,platform:'node',format:'cjs',packages:'external',tsconfig:'tsconfig.web.json',write:false});
function fixture(selectedId=null) {
  const calls=[];
  const directory={accountId:'a',organizationId:'o',selectedId,workspaces:[{id:'one',name:'One'},{id:'two',name:'Two'}]};
  const api=new Proxy({
    controlPlanes:async()=>({activeId:'hosted',profiles:[{id:'hosted',issuer:'https://portal.example'}]}),
    session:async()=>({email:'fixture@example.test'}),portalWorkspaces:async()=>directory,
    listAgents:async()=>{calls.push('agents');return [{id:'agent',name:'Eve',url:null}];},
    listSessions:async()=>[],listRooms:async()=>[],
    loadState:async()=>{calls.push('restore');return null;},
    saveState:async()=>{},selectPortalWorkspace:async()=>{},
  },{get:(target,key)=>target[key]??(()=>Promise.resolve(null))});
  const module={exports:{}};
  vm.runInNewContext(bundle.outputFiles[0].text,{module,exports:module.exports,require:createRequire(import.meta.url),console,Error,crypto:webcrypto,window:{studio:api,addEventListener:()=>{}},document:{addEventListener:()=>{},visibilityState:'hidden',hasFocus:()=>false},setInterval:()=>0,clearInterval:()=>{},setTimeout,clearTimeout,AbortController});
  return {store:module.exports.useStore,api,calls,directory};
}

function ready() {
 const f=fixture('one');
 f.store.setState({portalWorkspaceId:'one',agents:[{id:'eve',url:'http://fixture.invalid',name:'Eve'}],loadAgentInfo:async()=>{}});
 return f;
}
test('saved schedule without restart is not represented as activated',async()=>{
 const f=ready(); f.api.manage=async()=>({ok:true,status:200,data:{ok:true,restarted:false}});
 assert.equal(await f.store.getState().createSchedule('eve',{name:'check',cron:'* * * * *',instruction:'check'}),true);
 assert.match(f.store.getState().scheduleNotice.message,/not activated/);
});
test('scheduled restart is not proof of scheduler execution',async()=>{
 const f=ready(); f.api.manage=async()=>({ok:true,status:200,data:{ok:true,restarted:true}});
 await f.store.getState().createSchedule('eve',{name:'check',cron:'* * * * *',instruction:'check'});
 assert.match(f.store.getState().scheduleNotice.message,/not confirmed/);
 f.store.setState({scheduleNotice:null});
});
test('network ambiguity returns control and warns against a duplicate write',async()=>{
 const f=ready(); f.api.manage=async()=>{throw Error('connection reset')};
 assert.equal(await f.store.getState().createSchedule('eve',{}),false);
 assert.match(f.store.getState().manageError,/may already be saved/);
});
test('late schedule response cannot leak across workspaces',async()=>{
 const f=ready(); let finish; f.api.manage=()=>new Promise(r=>{finish=r});
 const pending=f.store.getState().createSchedule('eve',{});
 f.store.setState({portalWorkspaceId:'two'});finish({ok:true,data:{ok:true,restarted:false}});
 assert.equal(await pending,false); assert.equal(f.store.getState().scheduleNotice,null);
});
test('removal does not imply that an old scheduler was stopped',async()=>{
 const f=ready(); f.api.manage=async()=>({ok:true,data:{ok:true}});
 assert.equal(await f.store.getState().deleteSchedule('eve','check'),true);
 assert.match(f.store.getState().scheduleNotice.message,/Waiting for the production agent/);
 f.store.setState({scheduleNotice:null});
});

test('missing management blocks save without falling back to legacy writer',async()=>{
 const f=ready();const calls=[];f.api.manage=async input=>{calls.push(input);return {ok:false,status:404,data:{}}};
 assert.equal(await f.store.getState().createSchedule('eve',{name:'check',cron:'* * * * *',instruction:'check'}),false);
 assert.equal(calls.length,1);assert.equal(calls[0].path,'/tealbrick/management');assert.equal(calls[0].body,undefined);
});
test('routine save requests native build-restart with idempotency key',async()=>{
 const f=ready();const calls=[];f.api.manage=async input=>{calls.push(input);return {ok:true,status:202,data:{ok:true,restarted:false}}};
 await f.store.getState().createSchedule('eve',{name:'Morning check',cron:'* * * * *',instruction:'check'});
 assert.equal(calls[1].path,'/tealbrick/management');assert.equal(calls[1].body.operation,'upsert');assert.equal(calls[1].body.name,'morning-check');assert.match(calls[1].body.requestId,/^[a-f0-9-]{36}$/);
});

test('routine host wake is forwarded only when explicitly selected',async()=>{
 for(const wake of [undefined,false,true]){
  const f=ready();const calls=[];f.api.manage=async input=>{calls.push(input);return {ok:true,status:202,data:{ok:true,restarted:false}}};
  await f.store.getState().createSchedule('eve',{name:'wake check',cron:'0 9 * * *',instruction:'check',...(wake===undefined?{}:{wake})});
  assert.equal(calls[1].body.wake,wake);
 }
});
test('routine deliveries appear once in chat and never become user messages',async()=>{
 const f=ready();f.api.manage=async()=>({ok:true,data:{deliveries:[{id:'turn-1',text:'Hi',at:1000,name:'hi'}]}});
 await f.store.getState().syncRoutineDeliveries();await f.store.getState().syncRoutineDeliveries();
 assert.equal(f.store.getState().conversations.eve.length,1);assert.equal(f.store.getState().conversations.eve[0].role,'agent');
});
test('late routine delivery cannot cross workspace selection',async()=>{
 const f=ready();let finish;f.api.manage=()=>new Promise(r=>finish=r);
 const pending=f.store.getState().syncRoutineDeliveries();f.store.setState({portalWorkspaceId:'two'});finish({ok:true,data:{deliveries:[{id:'old',text:'Hi',at:1}]}});await pending;
 assert.equal(f.store.getState().conversations.eve,undefined);
});
test('agent info publishes even when optional management throws',async()=>{
 const f=ready();f.api.agentInfo=async()=>({schedules:[{name:'hi',cron:'*/5 * * * *'}]});f.api.manage=async()=>{throw Error('missing')};
 // Use actual implementation rather than ready's deliberate observation stub.
 const real=fixture('one');real.store.setState({portalWorkspaceId:'one',agents:f.store.getState().agents});real.api.agentInfo=f.api.agentInfo;real.api.manage=f.api.manage;
 await real.store.getState().loadAgentInfo('eve');assert.equal(real.store.getState().details.eve.schedules[0].name,'hi');
});
test('agent without endpoint reports a bounded unavailable state instead of loading forever',async()=>{
 const f=fixture('one');f.store.setState({activeAgentId:'eve',agents:[{id:'eve',name:'Eve',url:null}]});
 await f.store.getState().loadAgentInfo('eve');assert.match(f.store.getState().infoError,/no desktop endpoint/);
});
test('shared registry replaces static discovery with editable routine revisions and run state',async()=>{
 const f=fixture('one');f.store.setState({portalWorkspaceId:'one',agents:[{id:'eve',name:'Eve',url:'http://fixture.invalid'}]});
 f.api.agentInfo=async()=>({schedules:[{name:'dispatcher',cron:'* * * * *'}]});f.api.manage=async({path})=>path==='/tealbrick/management'?{ok:true,data:{dynamic:true,routines:[{name:'hi',cron:'*/5 * * * *',instruction:'Hi',enabled:true,revision:2}],runs:[{name:'hi',status:'completed',updatedAt:123}]}}:{ok:false};
 await f.store.getState().loadAgentInfo('eve');const rows=f.store.getState().details.eve.schedules;assert.equal(rows.length,1);assert.equal(rows[0].name,'hi');assert.equal(rows[0].revision,2);assert.equal(rows[0].lastRun.status,'completed');
});
test('desktop update sends observed revision and reports no restart for dynamic creation',async()=>{
 const f=ready(),calls=[];f.store.setState({details:{eve:{schedules:[{name:'hi',dynamic:true,revision:4}]}}});f.api.manage=async x=>{calls.push(x);return {ok:true,data:{ok:true,dynamic:true}}};
 assert.equal(await f.store.getState().updateSchedule('eve','hi',{enabled:false}),true);assert.equal(calls[0].body.revision,4);assert.equal(calls[0].body.enabled,false);
 await f.store.getState().createSchedule('eve',{name:'new',cron:'* * * * *',instruction:'Hi'});assert.match(f.store.getState().scheduleNotice.message,/No restart/);
});
test('an open editor retains its revision when polling observes an agent edit',async()=>{
 const f=ready(),calls=[];f.store.setState({details:{eve:{schedules:[{name:'hi',dynamic:true,revision:5}]}}});
 f.api.manage=async x=>{calls.push(x);return {ok:false,status:409,data:{error:'revision_conflict'}}};
 assert.equal(await f.store.getState().updateSchedule('eve','hi',{instruction:'stale desktop draft'},4),false);
 assert.equal(calls[0].body.revision,4);assert.match(f.store.getState().manageError,/changed elsewhere/);
});
