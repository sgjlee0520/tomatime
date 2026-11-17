// Checks for rules.js, mirroring Tests/RulesCheck.swift line for line. Run: npm test
import test from 'node:test';
import assert from 'node:assert/strict';
import * as R from './rules.js';

const t0 = 1_794_000_000_000, day = 86_400_000, min = 60_000;
const idle = R.idleStatus;
const focus = (endsAt) => ({ state: 'focus', tierName: 'Golden', minutes: 45, endsAt, sessionID: null });
const mk = (uid, status = idle, { joined = t0 - 30 * day, seconds = {} } = {}) =>
  ({ uid, name: uid, joinedAt: joined, hasPass: false, status, secondsByDevice: seconds });
const group = (members, unlocked = true) =>
  ({ id: 'g', name: 'G', ownerUID: members[0]?.uid ?? '', memberUIDs: members.map((m) => m.uid), unlocked, members });
const today = R.dayKey(t0);

test('joining, states, friends', () => {
  const two = group([mk('a'), mk('b')]);
  assert.equal(R.joinVerdict(two, 'new', false), 'ok');
  assert.equal(R.joinVerdict({ ...two, unlocked: false }, 'new', false), 'needsPass');
  assert.equal(R.joinVerdict({ ...two, unlocked: false }, 'new', true), 'ok');
  assert.equal(R.joinVerdict(group([1, 2, 3, 4, 5, 6].map((i) => mk(`m${i}`))), 'new', true), 'full');
  assert.equal(R.joinVerdict(two, 'a', false), 'alreadyMember');
  assert.equal(R.effectiveState(focus(t0 - 1000), t0), 'idle');
  assert.equal(R.effectiveState(focus(t0 + min), t0), 'focus');
  assert.equal(R.effectiveState({ ...idle, state: 'break', minutes: 10, endsAt: t0 - 5000 }, t0), 'idle');
  const g1 = group([mk('me', focus(t0 + 10 * min)), mk('A', focus(t0 + 10 * min))]);
  const g2 = group([mk('me'), mk('A', focus(t0 + 10 * min)), mk('B', focus(t0 + min)), mk('C', focus(t0 - min))]);
  assert.equal(R.friendsFocusing([g1, g2], 'me', t0), 2);
});

test('minutes: one rounding rule everywhere', () => {
  assert.equal(R.statusText(mk('x', focus(t0 + 31 * min)), t0), 'Golden · 31 min');
  assert.equal(R.statusText(mk('x', { ...idle, state: 'break', minutes: 10, endsAt: t0 + 4 * min }), t0), 'break · 4 min');
  assert.equal(R.statusText(mk('x', idle, { seconds: { d: { [today]: 2700 } } }), t0), '45 min today');
  assert.equal(R.statusText(mk('x', idle, { seconds: { d: { [today]: 1499.995 } } }), t0), '25 min today');  // finished 25 → 25
  assert.deepEqual([1499.995, 1499.4, 2850.2].map(R.wholeMinutes), [25, 24, 47]);
  const half = group([mk('p', idle, { seconds: { a: { [today]: 1499.995 } } }), mk('q', idle, { seconds: { b: { [today]: 1530 } } })]);
  assert.deepEqual(R.groupDayMinutes(half, [t0]), [50]);
  assert.deepEqual(R.weeklyRanking(half, t0, 0).map((r) => r.minutes), [25, 25]);
  assert.equal(R.memberSeconds(mk('x', idle, { joined: t0, seconds: { a: { [today]: 600 }, b: { [today]: 300 } } }), t0), 900);
  assert.equal(R.memberSeconds(mk('x', idle, { joined: t0, seconds: { a: { [R.dayKey(t0 - day)]: 600 } } }), t0 - day), 0);
  const dm = group([mk('p', idle, { seconds: { a: { [today]: 1500 } } }), mk('q', idle, { seconds: { b: { [today]: 1200 } } })]);
  assert.deepEqual(R.groupDayMinutes(dm, [t0 - day, t0]), [0, 45]);
  assert.deepEqual(R.dayRanking(dm, t0).map((r) => `${r.name} ${r.minutes}`), ['p 25', 'q 20']);
  assert.deepEqual(R.dayRanking(dm, t0 - day).map((r) => `${r.name} ${r.minutes}`), ['p 0', 'q 0']);
});

test('weekly ranking: this week only, sorted, ties alphabetical', () => {
  const lastWeek = R.dayKey(t0 - 8 * day), s = (o) => ({ seconds: { d: o } });
  const ranked = R.weeklyRanking(group([
    mk('Jun', idle, s({ [today]: 230 * 60, [lastWeek]: 300 * 60 })), mk('Alex', idle, s({ [today]: 365 * 60 })),
    mk('Mina', idle, s({ [today]: 580 * 60 })), mk('You', idle, s({ [today]: 495 * 60 }))]), t0, 0);
  assert.deepEqual(ranked.map((r) => r.name), ['Mina', 'You', 'Alex', 'Jun']);
  assert.equal(ranked.at(-1).minutes, 230);
  const tie = R.weeklyRanking(group([mk('Zed', idle, s({ [today]: 600 })), mk('Amy', idle, s({ [today]: 600 }))]), t0, 0);
  assert.deepEqual(tie.map((r) => r.name), ['Amy', 'Zed']);
});

const gs = (startAt, o = {}) => ({ id: 's', round: 1, startedBy: 'a', starterName: 'A', tierName: 'Red', minutes: 25,
  startAt, cancelled: false, joined: ['a'], nextJoined: [], devices: { a: 'macA' }, plan: [], nextTierName: null, nextMinutes: null,
  nextRound: null, ...o });

test('session phase, start rule, menu line', () => {
  assert.deepEqual(R.sessionPhase(gs(t0 + 7000), t0), { kind: 'countdown', seconds: 7 });
  assert.deepEqual(R.sessionPhase(gs(t0 + 6200), t0), { kind: 'countdown', seconds: 7 });
  assert.deepEqual(R.sessionPhase(gs(t0 - 7 * min), t0), { kind: 'running', left: 1080 });
  assert.equal(R.sessionPhase(gs(t0 - 30 * min), t0).kind, 'over');
  assert.equal(R.sessionPhase(gs(t0 + 5000, { cancelled: true }), t0).kind, 'over');
  assert.equal(R.nextRoundStart(gs(t0 - 25 * min)), t0 + 10 * min);
  assert.ok(R.shouldAutoJoin(30) && !R.shouldAutoJoin(150));

  const groupBreak = gs(t0 - 27 * min, { nextJoined: ['a'] });  // ended 2 min ago; next round at t0 + 8 min
  assert.ok(R.canStartSession(null, t0));
  assert.ok(!R.canStartSession(gs(t0 + 5000), t0));
  assert.ok(!R.canStartSession(gs(t0 - min), t0));
  assert.ok(R.canStartSession(gs(t0 - 30 * min), t0));
  assert.ok(!R.canStartSession(groupBreak, t0));
  assert.ok(R.canStartSession(groupBreak, t0 + 10 * min));
  assert.ok(R.canStartSession(gs(t0 + 5000, { cancelled: true }), t0));

  const running = gs(t0 - 7 * min), menu = (...a) => R.sessionMenu(...a);
  assert.deepEqual(menu(null, 'b', 'macB', false, t0), { kind: 'start' });
  assert.deepEqual(menu(gs(t0 + 5000), 'b', 'macB', false, t0), { kind: 'joinCountdown' });
  assert.deepEqual(menu(gs(t0 + 5000), 'b', 'macB', true, t0), { kind: 'starting' });
  assert.deepEqual(menu(gs(t0 + 5000), 'a', 'macB', false, t0), { kind: 'starting' });
  assert.deepEqual(menu(running, 'b', 'macB', false, t0), { kind: 'joinRunning', m: 18 });
  assert.deepEqual(menu(running, 'a', 'macA', true, t0), { kind: 'inIt', m: 18 });
  assert.deepEqual(menu(running, 'a', 'macB', false, t0), { kind: 'otherDevice', m: 18 });
  assert.deepEqual(menu(groupBreak, 'b', 'macB', false, t0), { kind: 'joinBreak', m: 8 });
  assert.deepEqual(menu(groupBreak, 'a', 'macA', true, t0), { kind: 'onBreak', m: 8 });
  assert.deepEqual(menu(groupBreak, 'b', 'macB', false, t0 + 475_000), { kind: 'starting' });
  assert.deepEqual(menu(gs(t0 - 30 * min), 'b', 'macB', false, t0), { kind: 'start' });
});

test('countdown mode: what this PC shows', () => {
  const cd = (o = {}) => gs(t0 + 10_000, o), mode = (...a) => R.countdownMode(...a);
  assert.equal(mode(cd(), 'a', 'macA', false, 0), 'starter');
  assert.equal(mode(cd(), 'a', 'macB', true, 0), null);
  assert.equal(mode(cd(), 'b', 'macC', false, 0), 'invite');
  assert.equal(mode(cd(), 'b', 'macC', true, 30), 'autoJoin');
  assert.equal(mode(cd(), 'b', 'macC', true, 300), 'invite');
  const next = cd({ round: 2, joined: ['a', 'b'], devices: { a: 'macA', b: 'macC' } });
  assert.equal(mode(next, 'a', 'macA', false, 999), 'autoJoin');
  assert.equal(mode(next, 'b', 'macC', false, 999), 'autoJoin');
  assert.equal(mode(next, 'b', 'macD', true, 0), null);
  assert.ok(R.otherDeviceHasIt(next, 'b', 'macD') && !R.otherDeviceHasIt(next, 'b', 'macC') && !R.otherDeviceHasIt(cd(), 'b', 'macC'));
});

test('invite codes', () => {
  assert.match(R.makeInviteCode(), /^TOMA-[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{6}$/);
  const ok = 'TOMA-4K7QM2';
  for (const typed of [' toma-4k7qm2 ', '4k7qm2', 'toma 4k7qm2', 'TOMA4K7QM2', 'TOMA–4K7QM2', 'TOMA-4K7QM2.', '“TOMA-4K7QM2”', '4K7 QM2']) {
    assert.equal(R.normalizeCode(typed), ok, typed);
  }
  for (const bad of ['4K7Q', 'TOMA-4K7QM0', 'TOMA-4K7QM22']) assert.equal(R.normalizeCode(bad), null, bad);
});

test('Firestore boundary', () => {
  const stamp = (ms) => ({ toMillis: () => ms });  // what a Firestore Timestamp looks like to plain()
  const s = { state: 'focus', tierName: 'Red', minutes: 25, endsAt: t0 + 100_000, sessionID: 's1' };
  assert.deepEqual(R.statusData(s).endsAt, new Date(t0 + 100_000));
  const m = R.member('u', R.plain({ name: 'Mina', joinedAt: stamp(t0), hasPass: true,
    status: { ...s, endsAt: stamp(s.endsAt) }, secondsByDevice: { d: { [today]: 60 } } }));
  assert.deepEqual(m.status, s);
  assert.ok(m.name === 'Mina' && m.hasPass && m.joinedAt === t0 && m.secondsByDevice.d[today] === 60);
  assert.equal(R.member('u', { name: 'NoDate' }), null);
  const first = R.session(R.plain({ id: 'r1', round: 1, startedBy: 'a', starterName: 'A', tierName: 'Red', minutes: 25,
    createdAt: stamp(t0), cancelled: false, joined: ['a'], devices: { a: 'macA' } }));
  assert.ok(first.startAt === t0 + 10_000 && first.nextJoined.length === 0 && first.id === 'r1' && first.devices.a === 'macA');
  const later = R.session({ id: 'r2', round: 2, startedBy: 'a', minutes: 25, createdAt: t0, startAt: t0 + 900_000 });
  assert.ok(later.startAt === t0 + 900_000 && Object.keys(later.devices).length === 0);
  assert.deepEqual(R.secondsSince({ [R.dayKey(t0 - day)]: 60, [today]: 120, [R.dayKey(t0 + day)]: 30 }, t0),
    { [today]: 120, [R.dayKey(t0 + day)]: 30 });
});

test('withTimeout gives up on work that never finishes', async () => {
  const began = Date.now();
  await assert.rejects(R.withTimeout(() => new Promise(() => {}), 0.2), (e) => e.code === 'offline');
  assert.ok(Date.now() - began < 1000);
  assert.equal(await R.withTimeout(async () => 7), 7);
});

test('shared timer', () => {
  const now = t0 / 1000;
  const red = { phase: 'focus', tier: 'Red', minutes: 25, running: true, endAt: now + 1500, left: 1500, by: 'mac', at: now };
  const held = { ...red, running: false, endAt: null, left: 1400, by: 'phone' };
  assert.deepEqual(R.timerFrom(red), red);
  assert.deepEqual(R.timerFrom(held), held);
  assert.equal(R.timerFrom({ tier: 'Red' }), null);
  assert.ok(R.sameTimer(red, { ...red, endAt: red.endAt + 0.4, by: 'phone' }));
  assert.ok(!R.sameTimer(red, held) && !R.sameTimer(null, red) && !R.sameTimer(red, { ...held, running: true, endAt: now + 1900 }));
  assert.ok(R.sameTimer(R.idleTimer('a', t0), R.idleTimer('b', t0 + 9000)));
  assert.ok(R.sameTimer(held, { ...held, by: 'x' }));
  assert.deepEqual([24 * 60 + 12, 7444, 3600, 0.2].map(R.clock), ['24:12', '2:04:04', '60:00', '0:01']);
  assert.deepEqual(R.tiers.map((t) => t.minutes), [20, 25, 45, 60]);
  assert.equal(R.tierColor('30-min', 30), R.tiers[1].color);
  assert.equal(R.tierColor('Golden', 45), R.tiers[2].color);
});

import { tomatoBitmap, iconText } from './icon.js';
import { signInURL, waitForToken, newNonce } from './apple.js';

test('tray icon: a tomato with the minutes left on it', () => {
  for (const size of [16, 32]) {
    const plainTomato = tomatoBitmap(size, '#e63326'), numbered = tomatoBitmap(size, '#e63326', '24', true);
    assert.equal(plainTomato.length, size * size * 4);
    const at = (px, x, y) => [...px.subarray((y * size + x) * 4, (y * size + x) * 4 + 4)];
    assert.deepEqual(at(plainTomato, size / 2, Math.round(size * 0.75)), [0x26, 0x33, 0xe6, 255], 'red body (BGRA)');
    assert.equal(at(plainTomato, 0, 0)[3], 0, 'transparent corner');
    const white = (px) => { let n = 0; for (let i = 0; i < px.length; i += 4) if (px[i] === 255 && px[i + 1] === 255 && px[i + 2] === 255 && px[i + 3] === 255) n++; return n; };
    assert.equal(white(numbered), (11 + 9) * (size / 8) ** 2, 'the digits 2 and 4 in white');
  }
  assert.deepEqual([24.2 * 60, 60, 1, 99 * 60, 100 * 60, 480 * 60].map(iconText), ['25', '1', '1', '99', '2h', '8h']);
});

test('Sign in with Apple: the browser hands the token to this PC only', async () => {
  const rawNonce = newNonce(), state = 'abc';
  const url = new URL(signInURL({ clientId: 'com.example.signin', redirect: 'https://example.com/signin.html', port: 5555, state, rawNonce }));
  assert.equal(url.origin + url.pathname, 'https://appleid.apple.com/auth/authorize');
  const q = url.searchParams;
  assert.deepEqual([q.get('response_type'), q.get('response_mode'), q.get('state'), q.get('scope')], ['code id_token', 'fragment', '5555.abc', null]);
  assert.match(q.get('nonce'), /^[0-9a-f]{64}$/);
  assert.notEqual(q.get('nonce'), rawNonce);

  const w = waitForToken(state), port = await w.ready, post = (body) => fetch(`http://127.0.0.1:${port}/token`, { method: 'POST', body });
  assert.match(await (await fetch(`http://127.0.0.1:${port}/`)).text(), /fetch\('\/token'/);
  assert.equal((await post('state=1.wrong&id_token=evil')).status, 400);  // someone else's answer: ignored, still waiting
  assert.equal((await post(`state=${port}.abc&code=c&id_token=the.id.token`)).status, 200);
  assert.equal(await w.token, 'the.id.token');
  await assert.rejects(fetch(`http://127.0.0.1:${port}/`), 'the server is gone after one sign-in');

  const cancelled = waitForToken('s2'), p2 = await cancelled.ready;
  await fetch(`http://127.0.0.1:${p2}/token`, { method: 'POST', body: `state=${p2}.s2&error=user_cancelled_authorize` });
  await assert.rejects(cancelled.token, /user_cancelled_authorize/);
});

test('the next group tomato can be another length; Exam mode runs a plan', () => {
  const groupBreak = gs(t0 - 27 * min, { nextJoined: ['a'] }), running = gs(t0 - 7 * min);
  assert.deepEqual(R.nextTomato(groupBreak), { name: 'Red', minutes: 25 });
  const picked = { ...groupBreak, nextTierName: 'Golden', nextMinutes: 45, nextRound: 2 };
  assert.deepEqual(R.nextTomato(picked), { name: 'Golden', minutes: 45 });
  assert.equal(R.roundFix(picked), null);
  assert.deepEqual(R.roundFix({ ...picked, round: 2 }), { name: 'Golden', minutes: 45 });  // an older Tomatime moved the group on
  // Picked a moment early, while round 2 still runs for the others: round 2 stays as it is. A stale pick counts for nothing.
  assert.equal(R.roundFix({ ...picked, round: 2, nextRound: 3 }), null);
  assert.deepEqual(R.nextTomato({ ...picked, round: 2, nextRound: 3 }), { name: 'Golden', minutes: 45 });
  assert.deepEqual([R.roundFix({ ...picked, round: 4 }), R.nextTomato({ ...picked, round: 4 })], [null, { name: 'Red', minutes: 25 }]);
  const read = R.session({ id: 'r', startedBy: 'a', createdAt: t0, nextMinutes: 50, nextRound: 2, plan: [25, 8, 45] });
  assert.deepEqual([read.nextMinutes, read.nextRound, read.nextTierName, read.plan], [50, 2, null, [25, 8, 45]]);
  assert.deepEqual(R.nextTomato(gs(t0, { nextMinutes: 50, nextRound: 2 })), { name: '50-min', minutes: 50 });
  assert.ok(R.canResize(running, 45, t0) && !R.canResize(running, 7.5, t0) && !R.canResize(groupBreak, 45, t0));
  assert.ok(!R.canResize(gs(t0 - 25 * min + 8000), 45, t0), 'not in its last 10 seconds');

  const exam = (round, minutes, startAt = t0) => gs(startAt, { round, minutes, tierName: R.tomatoName(minutes), nextJoined: ['a'], plan: [25, 8, 45, 10, 60] });
  assert.equal(R.breakAfter(exam(1, 25)), 8);
  assert.equal(R.nextRoundStart(exam(1, 25)), t0 + 33 * min);
  assert.deepEqual(R.nextTomato(exam(1, 25)), { name: 'Golden', minutes: 45 });
  assert.deepEqual(R.nextTomato(exam(2, 45)), { name: 'Diamond', minutes: 60 });
  assert.equal(R.breakAfter(exam(3, 60)), null);
  assert.equal(R.nextRoundStart(exam(3, 60)), null);
  assert.ok(R.canStartSession(exam(3, 60, t0 - 61 * min), t0));
  assert.deepEqual(R.sessionMenu(exam(3, 60, t0 - 61 * min), 'a', 'macA', true, t0), { kind: 'start' });
  assert.deepEqual(R.sessionMenu(exam(1, 25, t0 - 27 * min), 'a', 'macA', true, t0), { kind: 'onBreak', m: 6 });
  assert.deepEqual(R.roundFix(exam(2, 25)), { name: 'Golden', minutes: 45 });
  assert.equal(R.roundFix(exam(2, 45)), null);
  assert.ok(!R.canResize(exam(1, 25, t0 - min), 45, t0));
  assert.deepEqual(R.parseExamPlan('25, 8, 45,10,45 10 60'), [25, 8, 45, 10, 45, 10, 60]);
  assert.deepEqual(R.parseExamPlan(' 50 10 50 '), [50, 10, 50]);
  for (const bad of ['25, 8', '25', '25, 0, 45', '25, 8, 500', '']) assert.equal(R.parseExamPlan(bad), null, bad);
  assert.deepEqual(R.parseExamPlan(R.recommendedExamPlan.join(', ')), R.recommendedExamPlan);
  assert.equal(R.examText([25, 8, 60, 10, 45]), '25 → 60 → 45 min');
});
