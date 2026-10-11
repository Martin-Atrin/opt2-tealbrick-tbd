import test from 'node:test';
import assert from 'node:assert/strict';
import { workspaceFooterLabel } from '../src/renderer/src/lib/workspaceLabel.ts';

test('account footer follows the selected workspace, never the account organization label', () => {
  const workspaces = [{ id: 'personal', name: 'Personal workspace' }, { id: 'canary', name: 'Aura Nucbox canary' }];
  assert.equal(workspaceFooterLabel(workspaces, 'canary'), 'Aura Nucbox canary');
  assert.equal(workspaceFooterLabel(workspaces, 'personal'), 'Personal workspace');
  assert.equal(workspaceFooterLabel(workspaces, null), 'No workspace selected');
  assert.equal(workspaceFooterLabel(workspaces, 'removed'), 'No workspace selected');
});
