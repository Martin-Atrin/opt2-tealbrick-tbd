import test from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';

for (const switchID of [2, -101]) test(`only reset owner ${switchID} can reset; stale requests cannot reset again`, async () => {
  const dir = await mkdtemp(join(tmpdir(), 'tbd-reset-'));
  const bundle = join(dir, 'helper.cjs');
  await build({entryPoints:['src/tbd/helper.ts'],outfile:bundle,bundle:true,platform:'node',format:'cjs',plugins:[{name:'test-services',setup(b){
    b.onResolve({filter:/^\.\.\/main\//},a=>({path:a.path,namespace:'fixture'}));
    b.onLoad({filter:/.*/,namespace:'fixture'},a=>({contents:
      a.path.endsWith('/ipc') ? `import { handlers, app } from ${JSON.stringify(resolve('src/tbd/platform.ts'))};
      export function registerIpc(){
        handlers.set('slow',async()=>{await new Promise(r=>setTimeout(r,50));return 'old result'});
        handlers.set('switch',()=>{app.emit('tbd:reset-session')});
      }` : a.path.endsWith('/asks') ? 'export const setAskWindow=()=>{};export const refuseAll=()=>{};' : '',loader:'ts',resolveDir:process.cwd()}));
  }}]});
  const p=spawn(process.execPath,[bundle],{env:{...process.env,TBD_CHAT_DATA:dir},stdio:['pipe','pipe','pipe']});
  const received=[];const readers=[];
  const lines=createInterface({input:p.stdout});
  lines.on('line',line=>{const m=JSON.parse(line);if(readers.length)readers.shift()(m);else received.push(m)});
  const read=()=>received.length?Promise.resolve(received.shift()):new Promise(r=>readers.push(r));
  const send=m=>p.stdin.write(JSON.stringify(m)+'\n');
  try {
    send({type:'init',key:Buffer.alloc(32,1).toString('base64')});assert.equal((await read()).type,'ready');
    send({id:1,channel:'slow'});send({id:switchID,channel:'switch'});
    assert.deepEqual(await read(),{type:'reset',id:switchID});
    const late=await read();assert.equal(late.type,'reply');assert.equal(late.id,1);assert.match(late.error,/workspace changed/);assert.equal(late.value,undefined);
    send({id:3,channel:'slow'});assert.match((await read()).error,/changing/);
    send({type:'shutdown'});await new Promise(r=>p.once('exit',r));assert.equal(p.exitCode,0);
  } finally {p.kill();lines.close();await rm(dir,{recursive:true,force:true});}
});
