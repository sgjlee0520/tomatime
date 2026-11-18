// The timer and Groups end to end, in plain Node against the local Firebase emulators, with the real security
// rules: two people (two Cores) in one group, and one person on two devices. No windows are shown.
// Run: npm run test:live   (tools/test-windows.sh starts the emulators around it)
import test from 'node:test';
import assert from 'node:assert/strict';
import { signInWithEmailAndPassword, createUserWithEmailAndPassword } from '@firebase/auth';
import { doc, getDoc, updateDoc } from '@firebase/firestore';
import { GroupStore } from './store.js';
import { Core } from './core.js';
import { dayKey, effectiveState } from './rules.js';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(what, cond, ms = 8000) {
  for (const t0 = Date.now(); Date.now() - t0 < ms; await sleep(50)) if (cond()) return;
  assert.fail(`timed out waiting for: ${what}`);
}

// One device: a store, a core, and a pretend screen that remembers what it was asked to show.
function device(name, { unit = 1 } = {}) {
  const saved = new Map(), shown = { done: null, countdown: null, sounds: [] };
  const ui = { render() {}, sound: (s) => shown.sounds.push(s),
    showDone: (info) => { shown.done = info; }, closeDone: () => { shown.done = null; },
    showCountdown: (info) => { shown.countdown = info; }, closeCountdown: () => { shown.countdown = null; },
    countdownNames: (joined, waiting) => { if (shown.countdown) Object.assign(shown.countdown, { joined, waiting }); } };
  const settings = { get: (k, fallback) => (saved.has(k) ? saved.get(k) : fallback), set: (k, v) => saved.set(k, v) };
  const deviceKey = `focus-${name}-${crypto.randomUUID()}`;
  const store = new GroupStore({ config: null, deviceKey });
  const core = new Core({ store, settings, ui, deviceKey, unit, emulator: true });
  return { name, store, core, shown, settings, deviceKey };
}

const run = String(Date.now()).slice(-6);
const owner = device('owner'), pc = device('pc');
let gid, code;
const mine = (d) => d.store.groups[0]?.members.find((m) => m.uid === d.store.uid);
const seenBy = (viewer, d) => viewer.store.groups[0]?.members.find((m) => m.uid === d.store.uid);

test('code + name is enough to join a group', async () => {
  for (const d of [owner, pc]) { await d.store.start(); await d.store.signInWithCode(); await d.store.setName(d.name === 'pc' ? 'Windows PC' : 'Owner'); }
  assert.ok(pc.store.anonymous && pc.store.uid !== owner.store.uid);
  code = await owner.store.createGroup(`Test ${run}`);
  await assert.rejects(pc.store.join('TOMA-222222'), (e) => e.code === 'noSuchCode');
  assert.equal(await pc.store.join(code.toLowerCase().replace('-', ' ')), 'ok');
  await until('both see two members', () => owner.store.groups[0]?.members.length === 2 && pc.store.groups[0]?.members.length === 2);
  gid = pc.store.groups[0].id;
  assert.equal(await pc.store.join(code), 'alreadyMember');
  assert.equal(pc.store.code(gid), code);
  assert.deepEqual(owner.store.groups[0].members.map((m) => m.name), ['Owner', 'Windows PC']);
});

test('a solo tomato on the PC shows in the group, ends on the red screen, and its minutes count', async () => {
  pc.core.customTomato(3);  // 3 "minutes" = 3 s with unit 1
  await until('owner sees the PC focusing', () => seenBy(owner, pc)?.status.state === 'focus');
  assert.equal(seenBy(owner, pc).status.tierName, '3-min');
  await until('red screen', () => pc.shown.done, 6000);
  assert.deepEqual({ ...pc.shown.done, today: '' }, { tierName: '3-min', color: '#73c740', focused: 3, today: '', inGroup: false, canExtend: true, groupBreak: 10, exam: null });
  assert.deepEqual(pc.shown.sounds, ['focusEnd']);
  pc.core.startBreak(5);
  await until('owner sees the PC on a break', () => seenBy(owner, pc)?.status.state === 'break');
  assert.equal(pc.shown.done, null);
  pc.core.resetTapped();
  await until('owner sees the PC idle with its minutes', () => {
    const m = seenBy(owner, pc);
    return m?.status.state === 'idle' && Object.values(m.secondsByDevice)[0]?.[dayKey()] > 150;
  });
  const secs = Object.values(seenBy(owner, pc).secondsByDevice)[0][dayKey()];
  assert.ok(secs > 150 && secs <= 181, `about 3 minutes, got ${secs} s`);
  assert.match(pc.core.todayText(), /^[23] tomato minutes today$/);
});

test('group tomato: invite, join, start at the same second, red screen, group break, next round', async () => {
  await owner.store.startSession(gid, 'Red', 0.1);  // a 6-second group tomato
  await assert.rejects(pc.store.startSession(gid, 'Green', 20), (e) => e.code === 'busy');
  await until('both countdowns', () => owner.shown.countdown && pc.shown.countdown);
  assert.equal(owner.shown.countdown.mode, 'starter');
  assert.equal(pc.shown.countdown.mode, 'invite');
  assert.equal(pc.shown.countdown.title, `Test ${run}: Owner started a 🍅 Red tomato · 0 min`);
  assert.deepEqual([pc.shown.countdown.joined, pc.shown.countdown.waiting], [['Owner'], ['You']]);
  const sid = pc.shown.countdown.sid;
  pc.core.joinRound(gid, sid);  // the Join button
  await until('the owner sees the PC joined', () => owner.shown.countdown?.joined.length === 2);
  await until('both running', () => owner.core.group.sid === sid && pc.core.group.sid === sid, 12000);
  assert.ok(Math.abs(owner.core.end - pc.core.end) < 30, `same end: ${owner.core.end - pc.core.end} ms apart`);
  assert.ok(Math.abs(pc.core.end - (pc.store.sessions[gid].startAt + 6000)) < 30, 'ends when the group tomato ends');
  await until('the owner sees the PC in this group tomato', () => seenBy(owner, pc)?.status.sessionID === sid);
  await until('both red screens', () => owner.shown.done?.inGroup && pc.shown.done?.inGroup, 9000);

  owner.core.groupBreak(); pc.core.groupBreak();
  await until('both on the group break', () => pc.store.sessions[gid].nextJoined.length === 2);
  assert.ok(pc.core.onBreak && pc.core.end > Date.now() + 9 * 60000, 'break runs until the next round');
  assert.equal(seenBy(owner, pc)?.status.state, 'break');
  // Skip the 10 minutes (what firebase/tools/fake-member.mjs "next" does): the next round starts in 4 s.
  const s = pc.store.sessions[gid];
  await updateDoc(doc(pc.store.db, 'groups', gid, 'sessions', 'current'),
    { round: 2, startAt: new Date(Date.now() + 4000), joined: s.nextJoined, nextJoined: [], id: 'round-2' });
  await until('next round countdown, no question asked', () => pc.shown.countdown?.sid === 'round-2' && owner.shown.countdown?.sid === 'round-2');
  assert.deepEqual([pc.shown.countdown.mode, pc.shown.countdown.note], ['autoJoin', 'You picked the group break']);
  await until('round 2 running on both', () => !pc.core.onBreak && pc.core.group.sid === 'round-2' && owner.core.group.sid === 'round-2', 8000);
  assert.ok(Math.abs(owner.core.end - pc.core.end) < 30);
});

test('pause leaves the group tomato (only me); the menu line joins it again late', async () => {
  pc.core.toggle();
  await until('the PC is out', () => !owner.store.sessions[gid].joined.includes(pc.store.uid));
  assert.ok(owner.store.sessions[gid].joined.includes(owner.store.uid) && owner.core.end != null, 'the owner keeps going');
  assert.equal(pc.core.group.gid, null);
  pc.core.joinGroupTapped(gid);
  await until('back in', () => owner.store.sessions[gid].joined.includes(pc.store.uid));
  assert.ok(Math.abs(owner.core.end - pc.core.end) < 30, 'a late joiner ends with everyone');
  pc.core.resetTapped(); owner.core.resetTapped();
});

test('a starter can cancel; skipping an invite starts nothing', async () => {
  await until('round 2 is over', () => Date.now() > owner.store.sessions[gid].startAt + 6500, 9000);
  await owner.store.startSession(gid, '90-min', 90);
  await until('invite', () => pc.shown.countdown?.mode === 'invite');
  assert.match(pc.shown.countdown.title, /Owner started a 🍅 90 min tomato$/);
  const sid = pc.shown.countdown.sid;
  owner.core.cancelRound(gid, sid);
  await until('cancelled for everyone', () => pc.store.sessions[gid].cancelled && pc.shown.countdown === null);
  await sleep(1500);
  assert.ok(pc.core.end == null && owner.core.end == null, 'nothing started');
});

const current = () => doc(pc.store.db, 'groups', gid, 'sessions', 'current');
async function bothJoin(sidNot) {
  await until('invite', () => pc.shown.countdown && pc.shown.countdown.sid !== sidNot);
  const sid = pc.shown.countdown.sid;
  pc.core.joinRound(gid, sid);
  await until('both running', () => owner.core.group.sid === sid && pc.core.group.sid === sid && owner.core.end && pc.core.end, 14000);
  return sid;
}

test('a group tomato can change length while it runs, and the next one can be another tomato', async () => {
  await owner.store.startSession(gid, 'Red', 0.5);
  const sid = await bothJoin();
  assert.equal(pc.core.changeGroupTomato(gid, 'Green', 0.01), false, 'not to a length that is already over');
  assert.equal(pc.core.changeGroupTomato(gid, '72-s', 1.2), true);
  const startAt = pc.store.sessions[gid].startAt;
  await until('both follow the longer tomato', () => [owner, pc].every((d) => Math.abs(d.core.end - (startAt + 72000)) < 50 && d.core.group.tier.name === '72-s'));
  assert.ok(owner.shown.sounds.includes('change'));
  const soon = (Date.now() - startAt + 4000) / 60000;  // and shorter again, so this test can go on: over in 4 s
  await pc.store.setTomato(gid, sid, 'Red', soon, false);
  await until('both follow the shorter tomato', () => [owner, pc].every((d) => Math.abs(d.core.end - (startAt + soon * 60000)) < 50));
  assert.equal(pc.core.changeGroupTomato(gid, 'Golden', 45), false, 'not in its last 10 seconds');
  await until('both red screens', () => owner.shown.done?.inGroup && pc.shown.done?.inGroup, 12000);
  // A change that lands just after a tomato ran out here (it was made a moment before, elsewhere): on it goes.
  const longer = (Date.now() - startAt + 5000) / 60000;
  await pc.store.setTomato(gid, sid, 'Red', longer, false);
  await until('both go on, red screens gone', () => [owner, pc].every((d) => d.shown.done === null && Math.abs(d.core.end - (startAt + longer * 60000)) < 50));
  await until('both red screens', () => owner.shown.done?.inGroup && pc.shown.done?.inGroup, 12000);

  owner.core.groupBreak(2); pc.core.groupBreak();  // the owner taps "Golden 45" under the group break button
  await until('both on the break, Golden next', () => pc.store.sessions[gid].nextJoined.length === 2 && pc.store.sessions[gid].nextMinutes === 45);
  assert.equal(pc.store.sessions[gid].minutes, longer, 'the round that just ended keeps its length');
  assert.equal(pc.store.sessions[gid].nextRound, 2);
  assert.equal(pc.core.changeGroupTomato(gid, '7-s', 0.12), true);  // from the menu, during the break: a typed length
  await until('7-s next', () => owner.store.sessions[gid].nextMinutes === 0.12 && owner.store.sessions[gid].nextTierName === '7-s');
  await pc.store.advanceRound(gid, 1, Date.now() + 3000);  // what the break's end does, without the 10 minutes
  await until('round 2 running on both', () => [owner, pc].every((d) => !d.core.onBreak && d.core.group.tier?.name === '7-s'), 9000);
  const r2 = pc.store.sessions[gid];
  assert.deepEqual([r2.round, r2.minutes, r2.tierName, r2.nextMinutes, r2.nextTierName, r2.nextRound], [2, 0.12, '7-s', null, null, null]);
  await pc.store.advanceRound(gid, 2, Date.now() + 3000);  // a stale "break's over" while the tomato runs: nothing moves on
  await sleep(400);
  assert.equal(pc.store.sessions[gid].round, 2);
  assert.match(pc.shown.countdown?.title ?? owner.shown.countdown?.title ?? 'next group 🍅 7-s', /7-s/);
  assert.ok(Math.abs(pc.core.end - (r2.startAt + 7200)) < 50 && Math.abs(owner.core.end - pc.core.end) < 30);

  // An older Tomatime (1.2.2) moves the group on with the same tomato again; this one puts the round right.
  await until('both red screens again', () => owner.shown.done?.inGroup && pc.shown.done?.inGroup, 12000);
  owner.core.groupBreak(3); pc.core.groupBreak();
  await until('Diamond next', () => pc.store.sessions[gid].nextJoined.length === 2 && pc.store.sessions[gid].nextMinutes === 60);
  await updateDoc(current(), { round: 3, startAt: new Date(Date.now() + 4000), joined: pc.store.sessions[gid].nextJoined, nextJoined: [], id: 'old-app' });
  await until('put right', () => pc.store.sessions[gid].minutes === 60 && pc.store.sessions[gid].nextMinutes === null);
  await until('round 3 is a Diamond tomato on both', () => [owner, pc].every((d) => d.core.group.sid === 'old-app' && d.core.end && d.core.tier.minutes === 60), 9000);
  assert.ok(Math.abs(pc.core.end - (pc.store.sessions[gid].startAt + 3600000)) < 50);
  pc.core.resetTapped(); owner.core.resetTapped();
  await owner.store.cancelSession(gid, 'old-app');
  await until('cancelled', () => pc.store.sessions[gid].cancelled);
});

test('Exam mode in a group: breaks start by themselves, the plan sets each tomato, then it is done', async () => {
  owner.settings.set('examPlan', [0.1, 0.25, 0.1]);  // 6 s, a 15 s break, 6 s
  await owner.core.startGroupExam(gid);
  const sid = await bothJoin('old-app');
  assert.match(pc.shown.countdown?.title ?? 'Owner started Exam mode · 0.1 → 0.1 min', /Exam mode · 0\.1 → 0\.1 min$/);
  assert.deepEqual(pc.store.sessions[gid].plan, [0.1, 0.25, 0.1]);
  assert.equal(pc.core.changeGroupTomato(gid, 'Golden', 45), false, 'the plan sets the lengths');
  await until('the break started by itself on both', () => [owner, pc].every((d) => d.core.onBreak && d.shown.done?.exam), 12000);
  assert.equal(pc.shown.done.exam.title, 'Tomato 1 of 2 done!');
  assert.match(pc.shown.done.exam.sub, /^0\.25 min break, then a 0\.1 min tomato\.\n/);
  assert.equal(pc.store.sessions[gid].id, sid);
  await until('both opted in', () => pc.store.sessions[gid].nextJoined.length === 2);
  assert.ok(Math.abs(pc.core.end - (pc.store.sessions[gid].startAt + 21000)) < 50, 'the break is the plan\'s 15 s');
  await until('tomato 2 running on both', () => [owner, pc].every((d) => !d.core.onBreak && d.core.end && d.core.group.sid && d.core.group.sid !== sid), 20000);
  assert.equal(pc.store.sessions[gid].round, 2);
  assert.equal(pc.shown.done, null, 'the break screen closed');
  await until('done', () => [owner, pc].every((d) => d.shown.done?.exam?.done), 12000);
  assert.equal(pc.shown.done.exam.title, '📝 Exam mode done!');
  assert.match(pc.shown.done.exam.sub, /Go take a walk\.$/);
  await sleep(300);
  assert.deepEqual(pc.store.sessions[gid].nextJoined, [], 'no next round');
  pc.core.resetTapped(); owner.core.resetTapped();
  assert.ok(pc.core.end == null && pc.core.group.gid == null);
});

test('Exam mode alone: tomato, break, tomato, done; pause keeps it, another tomato ends it', async () => {
  pc.settings.set('examPlan', [2, 2, 3]);  // "minutes" are seconds here
  pc.core.examTapped();
  assert.deepEqual([pc.core.tier.name, pc.core.tier.minutes, pc.core.end != null], ['2-min', 2, true]);
  await until('break by itself', () => pc.core.onBreak && pc.shown.done?.exam?.title === 'Tomato 1 of 2 done!', 5000);
  assert.ok(pc.core.autoNext && pc.core.breakMinutes === 2);
  pc.core.toggle(); await sleep(300); pc.core.toggle();  // pause and resume the break
  await until('second tomato', () => !pc.core.onBreak && pc.core.end != null && pc.core.tier.minutes === 3, 5000);
  assert.equal(pc.shown.done, null);
  assert.equal(pc.core.exam.block, 1);
  await until('done', () => pc.shown.done?.exam?.done, 6000);
  assert.equal(pc.core.exam, null);
  pc.core.resetTapped();
  pc.core.examTapped();
  pc.core.pickTier(1);
  assert.ok(pc.core.exam == null && pc.core.end == null && pc.core.tier.name === 'Red');
});

test('one person, two devices: the shared timer follows start, pause and stop', async () => {
  const a = device('laptop'), b = device('desktop');
  const email = `two-${run}@fake.tomatime`;
  await a.store.start(); await b.store.start();
  await createUserWithEmailAndPassword(a.store.auth, email, 'password123');
  await signInWithEmailAndPassword(b.store.auth, email, 'password123');
  await until('same account on both', () => a.store.uid && a.store.uid === b.store.uid);
  assert.ok(!a.store.anonymous);
  await sleep(300);  // both listeners attached
  a.core.pickTier(3);
  a.core.toggle();  // Start a Diamond tomato (60 "minutes" = 60 s)
  await until('the other device runs it', () => b.core.end != null);
  assert.ok(Math.abs(a.core.end - b.core.end) < 30 && b.core.tier.name === 'Diamond');
  const saved = (await getDoc(doc(a.store.db, 'users', a.store.uid, 'timer', 'current'))).data();
  assert.deepEqual({ ...saved, endAt: 0, at: 0 }, { phase: 'focus', tier: 'Diamond', minutes: 60, running: true, endAt: 0, left: 60, by: a.deviceKey, at: 0 });
  b.core.toggle();  // pause on the other one
  await until('paused on both', () => a.core.end == null);
  assert.ok(Math.abs(a.core.left - b.core.left) < 1 && a.core.left > 50);
  a.core.customTomato(7);
  await until('a typed length carries over', () => b.core.tier.name === '7-min' && b.core.end != null);
  a.core.resetTapped();
  await until('stopped on both', () => b.core.end == null && b.core.custom?.name === '7-min');
  const idle = (await getDoc(doc(a.store.db, 'users', a.store.uid, 'timer', 'current'))).data();
  assert.equal(idle.phase, 'idle');
  // A break ends on both, but only the one that started it says so: the follower's "idle" could land after the
  // starter's next tomato and stop it. With that, Exam mode on one device survives its breaks.
  const shared = async () => (await getDoc(doc(a.store.db, 'users', a.store.uid, 'timer', 'current'))).data();
  a.settings.set('examPlan', [2, 2, 2, 2, 3]);
  a.core.examTapped();
  await until('the follower is on the first break', () => b.core.onBreak && b.core.end != null, 6000);
  assert.ok(!b.core.autoNext && b.core.exam == null);
  await until('the last tomato runs on both', () => a.core.exam?.block === 2 && a.core.end != null && b.core.end != null && b.core.tier.minutes === 3, 12000);
  assert.equal((await shared()).by, a.deviceKey, 'the follower wrote nothing at the breaks\' ends');
  b.core.toggle();  // pause from the other device: Exam mode goes on, and its own tomato pick is untouched
  await until('paused on both', () => a.core.end == null);
  assert.ok(a.core.exam && a.core.custom?.name === '7-min');
  b.core.toggle();
  await until('running again', () => a.core.end != null);
  await until('done', () => a.shown.done?.exam?.done, 6000);
  a.core.resetTapped();
  // A code sign-in has no other devices: it never writes a shared timer.
  assert.equal((await getDoc(doc(pc.store.db, 'users', pc.store.uid, 'timer', 'current'))).exists(), false);
});

test('"Delete my data" leaves the group and removes the name and the sign-in', async () => {
  const uid = pc.store.uid;
  await pc.store.deleteAccount();
  await until('signed out', () => !pc.store.signedIn);
  await until('the owner is alone', () => owner.store.groups[0]?.members.length === 1);
  assert.deepEqual(owner.store.groups[0].memberUIDs, [owner.store.uid]);
  assert.ok(!owner.store.groups[0].memberUIDs.includes(uid));
  assert.equal(effectiveState(mine(owner).status, Date.now()), 'idle');
  await owner.store.leave(gid);  // last one out deletes the group and its code
  await until('group gone', () => owner.store.groups.length === 0);
});

test.after(() => setTimeout(() => process.exit(), 200));  // Firestore keeps the process open
