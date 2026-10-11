import test from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
const bundle = await build({ entryPoints:['src/renderer/src/lib/scheduleActivation.ts'], bundle:true, platform:'node', format:'esm', write:false });
const { observeSchedule } = await import(`data:text/javascript;base64,${Buffer.from(bundle.outputFiles[0].text).toString('base64')}`);
const schedule={name:'digest',cron:'0 9 * * *',markdown:'Check inbox'};
const base={name:'digest',cron:schedule.cron,instruction:schedule.markdown,current:()=>true,attempts:3,wait:async()=>{}};
test('waits through old manifest and restart outage for exact production definition',async()=>{
 const responses=[{mode:'production',schedules:[]},null,{mode:'production',schedules:[schedule]}];
 assert.equal(await observeSchedule({...base,read:async()=>responses.shift()}),'loaded');
 assert.equal(responses.length,0);
});
test('development discovery is not cron activation',async()=>{
 assert.equal(await observeSchedule({...base,read:async()=>({mode:'development',schedules:[schedule]})}),'development');
});
test('stale definition and unknown runtime mode cannot confirm activation',async()=>{
 for(const raw of [{mode:'production',schedules:[{...schedule,markdown:'old'}]},{schedules:[schedule]}])
 assert.equal(await observeSchedule({...base,read:async()=>raw}),'pending');
});
test('workspace change during response cancels observation',async()=>{
 let current=true;
 assert.equal(await observeSchedule({...base,current:()=>current,read:async()=>{current=false;return {mode:'production',schedules:[schedule]}}}),'cancelled');
});
test('delivery handlers are confirmed by production handler presence, not discarded markdown',async()=>{
 assert.equal(await observeSchedule({name:'hi',cron:'*/5 * * * *',handler:true,current:()=>true,read:async()=>({mode:'production',schedules:[{name:'hi',cron:'*/5 * * * *',hasRun:true}]}),attempts:1}),'loaded');
});
