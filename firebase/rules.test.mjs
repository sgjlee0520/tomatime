// Firestore security rules for Tomatime Groups. Run via tools/test.sh (starts the emulator).
import { test, before, beforeEach, after } from 'node:test';
import { readFileSync } from 'node:fs';
import { initializeTestEnvironment, assertSucceeds, assertFails } from '@firebase/rules-unit-testing';
import { doc, getDoc, getDocs, collection, setDoc, updateDoc, deleteDoc, writeBatch } from 'firebase/firestore';

let env;
const CODE = 'TOMA-AAAAAA';
const member = (name, hasPass = false) => ({
  name, joinedAt: new Date(), hasPass,
  status: { state: 'idle', tierName: '', minutes: 0, endsAt: null, sessionID: null }, secondsByDevice: {},
});
const groupDoc = (uids, unlocked = true, code = CODE) =>
  ({ name: 'Physics', code, ownerUID: uids[0], memberUIDs: uids, unlocked, createdAt: new Date() });

before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'demo-tomatime',
    firestore: { rules: readFileSync(new URL('./firestore.rules', import.meta.url), 'utf8') },
  });
});
after(() => env.cleanup());
beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    const six = ['owner', 'm2', 'm3', 'm4', 'm5', 'm6'];
    for (const [gid, uids, unlocked] of [['g1', ['owner', 'mina'], true], ['locked', ['owner', 'mina'], false], ['full', six, true]]) {
      await setDoc(doc(db, 'groups', gid), groupDoc(uids, unlocked));
      for (const uid of uids) await setDoc(doc(db, 'groups', gid, 'members', uid), member(uid));
    }
    await setDoc(doc(db, 'codes', CODE), { groupID: 'g1' });
  });
});

const as = (uid) => env.authenticatedContext(uid).firestore();
// withSecurityRulesDisabled resolves to undefined, so read the group into a variable first.
const join = async (uid, gid, { code = CODE, who = uid, hasPass = false } = {}) => {
  let g;
  await env.withSecurityRulesDisabled(async (ctx) => { g = (await getDoc(doc(ctx.firestore(), 'groups', gid))).data(); });
  const db = as(uid), b = writeBatch(db);
  b.update(doc(db, 'groups', gid), { memberUIDs: [...g.memberUIDs, who] });
  b.set(doc(db, 'groups', gid, 'members', uid), { ...member(uid, hasPass), joinCode: code });
  return b.commit();
};

test('1. only members read a group and its members', async () => {
  await assertFails(getDoc(doc(as('stranger'), 'groups', 'g1')));
  await assertFails(getDocs(collection(as('stranger'), 'groups', 'g1', 'members')));
  await assertSucceeds(getDoc(doc(as('mina'), 'groups', 'g1')));
  await assertSucceeds(getDocs(collection(as('mina'), 'groups', 'g1', 'members')));
});

test('2. signed-in users can get a code but not list codes', async () => {
  await assertSucceeds(getDoc(doc(as('stranger'), 'codes', CODE)));
  await assertFails(getDocs(collection(as('stranger'), 'codes')));
  await assertFails(getDoc(doc(env.unauthenticatedContext().firestore(), 'codes', CODE)));
});

test('3. join needs the right code and only adds yourself', async () => {
  // a stale joinCode left in the group doc by an earlier joiner must not let a stranger in
  await env.withSecurityRulesDisabled((ctx) => updateDoc(doc(ctx.firestore(), 'groups', 'g1'), { joinCode: CODE }));
  await assertFails(join('jun', 'g1', { code: 'TOMA-BBBBBB' }));
  await assertFails(join('jun', 'g1', { who: 'someoneElse' }));
  await assertSucceeds(join('jun', 'g1'));
});

test('4. a 7th person cannot join', async () => {
  await assertFails(join('jun', 'full', { hasPass: true }));
});

test('5. a locked group needs a pass', async () => {
  await assertFails(join('jun', 'locked'));
  await assertSucceeds(join('jun', 'locked', { hasPass: true }));
});

test('6. members write only their own member doc', async () => {
  const status = { state: 'focus', tierName: 'Red', minutes: 25, endsAt: new Date(), sessionID: null };
  await assertSucceeds(updateDoc(doc(as('mina'), 'groups', 'g1', 'members', 'mina'), { status }));
  await assertFails(updateDoc(doc(as('mina'), 'groups', 'g1', 'members', 'owner'), { status }));
});

test('7. owner removes others; anyone removes themselves', async () => {
  const removeMina = (uid, left) => {
    const db = as(uid), b = writeBatch(db);
    b.update(doc(db, 'groups', 'g1'), { memberUIDs: left });
    b.delete(doc(db, 'groups', 'g1', 'members', 'mina'));
    return b.commit();
  };
  await assertSucceeds(removeMina('owner', ['owner']));
  await env.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'groups', 'g1'), groupDoc(['owner', 'mina', 'jun']));
    await setDoc(doc(ctx.firestore(), 'groups', 'g1', 'members', 'mina'), member('mina'));
    await setDoc(doc(ctx.firestore(), 'groups', 'g1', 'members', 'jun'), member('jun'));
  });
  await assertFails(removeMina('jun', ['owner', 'jun']));       // jun is not the owner
  await assertFails(removeMina('mina', ['owner']));             // leaving can't take jun along
  await assertSucceeds(removeMina('mina', ['owner', 'jun']));   // mina leaves on her own
});

test('8. owner renames and resets the code; ownership only passes when the owner leaves', async () => {
  await assertFails(updateDoc(doc(as('mina'), 'groups', 'g1'), { name: 'Hacked' }));
  await assertFails(updateDoc(doc(as('mina'), 'groups', 'g1'), { code: 'TOMA-CCCCCC' }));
  await assertFails(updateDoc(doc(as('mina'), 'groups', 'g1'), { ownerUID: 'mina' }));
  await assertSucceeds(updateDoc(doc(as('owner'), 'groups', 'g1'), { name: 'Physics 115', code: 'TOMA-CCCCCC' }));
  await assertFails(updateDoc(doc(as('owner'), 'groups', 'g1'), { ownerUID: 'mina' }));  // still a member: no
  await assertFails(updateDoc(doc(as('owner'), 'groups', 'g1'), { memberUIDs: ['mina'], ownerUID: 'stranger' }));
  await assertSucceeds(updateDoc(doc(as('owner'), 'groups', 'g1'), { memberUIDs: ['mina'], ownerUID: 'mina' }));
});

test('9. only members write the group session', async () => {
  const s = { round: 1, startedBy: 'mina', starterName: 'Mina', tierName: 'Red', minutes: 25, createdAt: new Date(),
              cancelled: false, joined: ['mina'], nextJoined: [] };
  await assertSucceeds(setDoc(doc(as('mina'), 'groups', 'g1', 'sessions', 'current'), s));
  await assertFails(setDoc(doc(as('stranger'), 'groups', 'g1', 'sessions', 'current'), s));
  await assertFails(getDoc(doc(as('stranger'), 'groups', 'g1', 'sessions', 'current')));
});

test('10. creating a group: you are the owner and the only member; the code points at it', async () => {
  const create = (uid, data) => {
    const db = as(uid), b = writeBatch(db);
    b.set(doc(db, 'groups', 'new'), data);
    b.set(doc(db, 'groups', 'new', 'members', uid), member(uid));
    b.set(doc(db, 'codes', 'TOMA-NNNNNN'), { groupID: 'new' });
    return b.commit();
  };
  await assertFails(create('jun', groupDoc(['someoneElse'], true, 'TOMA-NNNNNN')));
  await assertFails(create('jun', { ...groupDoc(['jun'], true, 'TOMA-NNNNNN'), memberUIDs: ['jun', 'mina'] }));
  await assertFails(create('jun', groupDoc(['jun'], true, 'TOMA-OTHERX')));  // code doc doesn't match
  await assertSucceeds(create('jun', groupDoc(['jun'], true, 'TOMA-NNNNNN')));
  await assertFails(setDoc(doc(as('mina'), 'codes', CODE), { groupID: 'new' }));  // can't hijack a code
});

test('11. users write only their own name', async () => {
  await assertSucceeds(setDoc(doc(as('mina'), 'users', 'mina'), { name: 'Mina' }));
  await assertFails(setDoc(doc(as('mina'), 'users', 'jun'), { name: 'Jun' }));
});

// Shared timer + device push tokens: only the person themself.
test('timer and devices: owner only', async () => {
  const timer = { phase: 'focus', tier: 'Red', minutes: 25, running: true, endAt: 1, left: 1500, by: 'mac', at: 0 };
  await assertSucceeds(setDoc(doc(as('mina'), 'users/mina/timer/current'), timer));
  await assertSucceeds(getDoc(doc(as('mina'), 'users/mina/timer/current')));
  await assertSucceeds(setDoc(doc(as('mina'), 'users/mina/devices/phone'), { platform: 'ios', apns: 'ab' }));
  await assertSucceeds(getDocs(collection(as('mina'), 'users/mina/devices')));
  await assertFails(getDoc(doc(as('alex'), 'users/mina/timer/current')));
  await assertFails(setDoc(doc(as('alex'), 'users/mina/timer/current'), timer));
  await assertFails(getDocs(collection(as('alex'), 'users/mina/devices')));
  await assertFails(getDoc(doc(env.unauthenticatedContext().firestore(), 'users/mina/timer/current')));
});
