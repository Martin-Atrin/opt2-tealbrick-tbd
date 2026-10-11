import test from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { publicSession, legacyPortalExecutionEnabled, sessionDirectoryRecord, debugStreamEnabled, streamDiagnostic } from '../src/main/portalPrivacy.ts';

const secretSession = {token:'ACCESS_SECRET',bundle:'BUNDLE_SECRET',refreshToken:'REFRESH_SECRET',expiresAt:123,email:'a@example.test',orgName:'Org',extra:'FUTURE_SECRET'};
async function fixture(entry, modules = {}, globals = {}) {
  const result = await build({entryPoints:[entry],bundle:true,platform:'node',format:'cjs',write:false,plugins:[{name:'boundaries',setup(b){
    b.onResolve({filter:/.*/},args => args.kind !== 'entry-point' && !args.path.endsWith('/portalPrivacy') && !args.path.endsWith('/agentCredentials') ? {path:args.path,external:true} : undefined);
  }}]});
  const module={exports:{}};
  const fallback=new Proxy({}, {get:()=>()=>undefined});
  vm.runInNewContext(result.outputFiles[0].text,{
    module,exports:module.exports,process:{env:{}},console:{log(){},warn(){}},Buffer,URL,AbortSignal,
    require:name=>modules[name] ?? (name.startsWith('node:') ? createRequire(import.meta.url)(name) : fallback),
    ...globals,
  });
  return module.exports;
}

test('public session and actual session IPC never expose current or future credentials', async()=>{
  const expected={expiresAt:123,email:'a@example.test',orgName:'Org'};
  assert.deepEqual(publicSession(secretSession),expected);
  assert.equal(publicSession(null),null);
  const handlers=new Map();
  const api=await fixture('src/main/ipc.ts',{
    electron:{ipcMain:{handle:(name,fn)=>handlers.set(name,fn),on(){}}},
    './controlPlane':{currentSession:()=>secretSession,startDeviceAuth:async()=>({userCode:'123',verificationUri:'https://example.test',deviceCode:'PRIVATE_DEVICE'}),pollDeviceAuth:async()=>secretSession},
  });
  api.registerIpc();
  assert.deepEqual(JSON.parse(JSON.stringify(handlers.get('studio:session')())),expected);
  await handlers.get('studio:signIn')();
  assert.deepEqual(JSON.parse(JSON.stringify(await handlers.get('studio:awaitSignIn')())),expected);
});

test('legacy execution requires an explicit exact private origin and cannot enable hosted services',()=>{
  const env={TEAL_BRICK_ALLOW_LEGACY_EXECUTION:'1',TEAL_BRICK_LEGACY_EXECUTION_ISSUER:'https://customer.example'};
  assert.equal(legacyPortalExecutionEnabled('https://customer.example',env),true);
  for(const origin of ['https://portal.tealbrick.com','https://agent.kybernesis.ai','https://other.example','http://customer.example','https://customer.example/path']) {
    assert.equal(legacyPortalExecutionEnabled(origin,env),false);
  }
  for(const origin of ['https://portal.tealbrick.com','https://agent.kybernesis.ai','https://portal.tealbrick.com.','https://agent.kybernesis.ai.']) {
    assert.equal(legacyPortalExecutionEnabled(origin,{...env,TEAL_BRICK_LEGACY_EXECUTION_ISSUER:origin}),false);
  }
  assert.equal(legacyPortalExecutionEnabled('https://customer.example',{}),false);
  assert.equal(legacyPortalExecutionEnabled('https://customer.example',{...env,TEAL_BRICK_ALLOW_LEGACY_EXECUTION:'true'}),false);
});

test('hosted connector/local provisioning operations reject before making any network request',async()=>{
  let calls=0;
  const api=await fixture('src/main/controlPlane.ts',{'./controlPlanes':{currentControlPlane:()=>({issuer:'https://portal.tealbrick.com'})}}, {fetch:async()=>{calls++;throw Error('network must not run');}});
  for(const action of ['addCustomConnector','connectService','startMcpSignIn','testRemoteMcp','provisionLocalAccess']) {
    const result=await api[action]({agent:'a',url:'https://customer.example',token:'SERVICE_SECRET'});
    assert.equal(result.ok,false,action);
    assert.match(result.error,/customer runtime/);
  }
  assert.equal(calls,0);
});

test('default local execution startup neither obtains device identity nor polls',async()=>{
  const api=await fixture('src/main/localExec.ts',{'./controlPlane':{issuer:()=> 'https://portal.tealbrick.com',deviceId:()=>{throw Error('device touched');}}},{fetch:()=>{throw Error('network touched');}});
  assert.doesNotThrow(()=>api.startLocalExec());
});

test('actual session recording drops previews, title, label and unknown fields before network serialization',async()=>{
  const requests=[];
  const api=await fixture('src/main/sessionIndex.ts',{
    './controlPlane':{activeSession:async()=>secretSession,issuer:()=> 'https://portal.tealbrick.com',authHeaders:()=>({authorization:'Bearer fixture'})},
    './portalWorkspaces':{selectedPortalWorkspace:()=> 'workspace-1'},
  },{fetch:async(url,init)=>{requests.push({url,body:JSON.parse(init.body)});return {ok:true};}});
  await api.recordSession({agent:'a',sessionId:'s',lastMessageAt:123,archived:false,title:'PRIVATE_TITLE',label:'PRIVATE_LABEL',lastMessagePreview:'PRIVATE_RESPONSE',future:'SECRET'});
  assert.deepEqual(requests[0].body,{agent:'a',sessionId:'s',lastMessageAt:123,archived:false,workspaceId:'workspace-1'});
  assert.doesNotMatch(JSON.stringify(sessionDirectoryRecord({agent:'a',sessionId:'s',token:'SECRET'},'w')),/SECRET/);
});

test('debug is explicit and diagnostics cannot serialize request or response bodies',()=>{
  for(const value of [undefined,'','0','false','yes','TRUE']) assert.equal(debugStreamEnabled(value),false);
  for(const value of ['1','true']) assert.equal(debugStreamEnabled(value),true);
  assert.equal(streamDiagnostic('input.requested'),'[stream] event=input.requested');
  assert.equal(streamDiagnostic('token=SECRET\n'),'[stream] event=unknown');
});

test('native app grants are read-only and land on the adapter capabilities route, not Eve kyb routes',async()=>{
  const api=await fixture('src/main/controlPlane.ts',{'./controlPlanes':{currentControlPlane:()=>({issuer:'https://portal.tealbrick.com'})}});
  assert.equal(api.manageEndpoint('https://agent.example:8444/','/tealbrick/capabilities',false),'https://agent.example:8444/tealbrick/v1/capabilities');
  assert.equal(api.manageEndpoint('https://agent.example:8444','/tealbrick/capabilities',true),null);
  assert.equal(api.manageEndpoint('https://a.example','/catalog',false),'https://a.example/eve/v1/kyb/catalog');
  assert.equal(api.manageEndpoint('https://a.example','/tealbrick/management',false),'https://a.example/eve/v1/tealbrick/management');
});
