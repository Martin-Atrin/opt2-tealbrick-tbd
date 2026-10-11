import { test } from 'node:test';
import assert from 'node:assert/strict';
import { choosePortalWorkspace, parseWorkspaceDirectory, workspaceAccountKey, workspaceStateName } from '../src/main/workspaceSelection.ts';
test('zero, single, multiple and deleted remembered workspace selection', () => {
  const a = { id: 'a', name: 'A' }, b = { id: 'b', name: 'B' };
  assert.equal(choosePortalWorkspace([]), null);
  assert.equal(choosePortalWorkspace([a]), 'a');
  assert.equal(choosePortalWorkspace([a, b]), null);
  assert.equal(choosePortalWorkspace([a, b], 'b'), 'b');
  assert.equal(choosePortalWorkspace([a, b], 'deleted'), null);
  assert.equal(choosePortalWorkspace([], 'a'), null);
});
test('storage is isolated by portal, account, organization and workspace; names cannot escape storage', () => {
  const directory = { accountId: 'u', organizationId: 'o', workspaces: [] };
  const key = workspaceAccountKey('https://portal.example', directory);
  const path = workspaceStateName(key, 'w', 'conversations.json');
  for (const [issuer, d, workspace] of [['https://other.example', directory, 'w'], ['https://portal.example', { ...directory, accountId: 'other' }, 'w'], ['https://portal.example', { ...directory, organizationId: 'other' }, 'w'], ['https://portal.example', directory, 'other']]) assert.notEqual(workspaceStateName(workspaceAccountKey(issuer, d), workspace, 'conversations.json'), path);
  assert.match(workspaceStateName(key, '../../secret', 'conversations.json'), /^workspace-[a-f0-9]{64}-conversations.json$/);
  assert.throws(() => workspaceStateName(key, 'w', '../session.bin'));
});
test('malformed directory fails closed rather than selecting an unscoped account', () => {
  for (const d of [null, {}, {accountId:'u', organizationId:'o',workspaces:[{id:'a',name:'A'},{id:'a',name:'B'}]}]) assert.throws(() => parseWorkspaceDirectory(d));
});
