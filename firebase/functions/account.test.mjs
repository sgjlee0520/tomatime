// Deleting an account takes the person out of every group the way leaving does on the Mac (GroupStore.leave).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { leavePlan } from './account.js';

const g = (uids, owner) => ({ memberUIDs: uids, ownerUID: owner, code: 'TOMA-AAAAAA' });
const m = (uid, joined) => ({ uid, joinedAt: new Date(joined) });

test('last member out deletes the group and its code', () => {
  assert.deepEqual(leavePlan(g(['me'], 'me'), [m('me', 1)], 'me'), { deleteGroup: true, code: 'TOMA-AAAAAA' });
});

test('a member leaves; the owner stays', () => {
  assert.deepEqual(leavePlan(g(['own', 'me'], 'own'), [m('own', 1), m('me', 2)], 'me'), { update: { memberUIDs: ['own'] } });
});

test('the owner leaves: the longest-standing member takes over', () => {
  const plan = leavePlan(g(['me', 'b', 'c'], 'me'), [m('me', 1), m('c', 2), m('b', 3)], 'me');
  assert.deepEqual(plan, { update: { memberUIDs: ['b', 'c'], ownerUID: 'c' } });
});

test('owner leaves, member docs missing: still hands the group on', () => {
  assert.deepEqual(leavePlan(g(['me', 'b'], 'me'), [], 'me'), { update: { memberUIDs: ['b'], ownerUID: 'b' } });
});
