import test from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { publicSession, debugStreamEnabled, streamDiagnostic } from '../src/main/portalPrivacy.ts';

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
    '../tbd/host':{ipcMain:{handle:(name,fn)=>handlers.set(name,fn),on(){}}},
    './controlPlane':{currentSession:()=>secretSession,startDeviceAuth:async()=>({userCode:'123',verificationUri:'https://example.test',deviceCode:'PRIVATE_DEVICE'}),pollDeviceAuth:async()=>secretSession},
  });
  api.registerIpc();
  assert.deepEqual(JSON.parse(JSON.stringify(handlers.get('studio:session')())),expected);
  await handlers.get('studio:signIn')();
  assert.deepEqual(JSON.parse(JSON.stringify(await handlers.get('studio:awaitSignIn')())),expected);
});

test('debug is explicit and diagnostics cannot serialize request or response bodies',()=>{
  for(const value of [undefined,'','0','false','yes','TRUE']) assert.equal(debugStreamEnabled(value),false);
  for(const value of ['1','true']) assert.equal(debugStreamEnabled(value),true);
  assert.equal(streamDiagnostic('input.requested'),'[stream] event=input.requested');
  assert.equal(streamDiagnostic('token=SECRET\n'),'[stream] event=unknown');
});
