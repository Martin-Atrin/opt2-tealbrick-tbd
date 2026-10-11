import test from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
const result = await build({entryPoints:['src/renderer/src/lib/agentInfo.ts'],bundle:true,platform:'node',format:'esm',write:false});
const {summarize} = await import(`data:text/javascript;base64,${Buffer.from(result.outputFiles[0].text).toString('base64')}`);
test('Codex is not presented as an Eve agent or assigned fictional tools',()=>{
 const x=summarize({harness:'codex',protocol:'app-server',name:'Local',capabilities:['chat','resume',null,7]});
 assert.equal(x.harness,'codex'); assert.equal(x.name,'Local');
 assert.deepEqual(x.capabilities,['chat','resume']);
 assert.deepEqual(x.schedules,[]); assert.deepEqual(x.tools,[]);
 assert.equal(x.channels[0].name,'Codex App Server');
});
test('Eve manifests retain their existing normalization',()=>{
 const x=summarize({agent:{name:'Canary'},tools:{authored:[{name:'recall'}]}});
 assert.equal(x.name,'Canary'); assert.equal(x.harness,undefined);
 assert.deepEqual(x.tools,[{name:'recall',description:undefined}]);
});
test('Any Teal Brick native adapter manifest is recognized by shape, not harness name',()=>{
 const x=summarize({harness:'claude',protocol:'tealbrick-native',name:'Agent',model:'claude-opus-5-5',capabilities:['chat','resume','cancel','session-access']});
 assert.equal(x.native,true); assert.equal(x.harness,'claude'); assert.equal(x.protocol,'tealbrick-native');
 assert.equal(x.model,'anthropic/claude-opus-5-5');
 assert.deepEqual(x.schedules,[]); assert.deepEqual(x.tools,[]);
 assert.equal(x.channels[0].name,'Claude Agent SDK');
});
test('An eve manifest that happens to carry harness/protocol fields stays eve',()=>{
 const x=summarize({harness:'eve',protocol:'eve',agent:{name:'Canary'}});
 assert.equal(x.native,undefined); assert.equal(x.name,'Canary');
});
