// Who gets which APNs push when the shared timer changes. Run: node --test (tools/test.sh).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { pushesFor } from './push.js';

const now = 1_794_000_000;
const red = { phase: 'focus', tier: 'Red', minutes: 25, running: true, endAt: now + 1500, left: 1500, by: 'mac', at: now };
const mac = { id: 'mac', platform: 'macos' };
const phone = { id: 'phone', platform: 'ios', apns: 'p1', pushToStart: 'pts' };
const watch = { id: 'watch', platform: 'watchos', apns: 'w1' };
const kinds = (ps) => ps.map((p) => `${p.deviceId}:${p.type}:${p.payload.aps.event ?? 'bg'}:${p.field}`);

test('a Mac start reaches the phone (background + Live Activity start) and the watch', () => {
  const ps = pushesFor(red, null, [mac, phone, watch], now);
  assert.deepEqual(kinds(ps), ['phone:background:bg:apns', 'phone:liveactivity:start:pushToStart', 'watch:background:bg:apns']);
  const start = ps[1].payload.aps;
  assert.equal(ps[1].topic, 'com.sgjlee.tomatime.push-type.liveactivity');
  assert.equal(ps[1].priority, 10);
  assert.equal(start['attributes-type'], 'TomatoActivity');
  assert.equal(start['input-push-token'], 1);
  assert.deepEqual(start.alert, { title: '🍅 Red tomato', body: '25 min focus' });
  assert.deepEqual(start['content-state'], { phase: 'focus', tier: 'Red', minutes: 25, running: true, endAt: now + 1500, left: 1500 });
  assert.equal(start['stale-date'], now + 1500);
  assert.equal(ps[0].topic, 'com.sgjlee.tomatime');
  assert.deepEqual(ps[0].payload.timer, red);
  assert.equal(ps[2].topic, 'com.sgjlee.tomatime.watchkitapp');
  assert.equal(ps[0].env, 'production');
});

test('pause in the same tomato updates the running Live Activity', () => {
  const paused = { ...red, running: false, endAt: null, left: 1400, by: 'mac', at: now + 100 };
  const ps = pushesFor(paused, red, [{ ...phone, activity: 'act' }], now + 100);
  assert.deepEqual(kinds(ps), ['phone:background:bg:apns', 'phone:liveactivity:update:activity']);
  assert.equal(ps[1].token, 'act');
  assert.equal(ps[1].payload.aps['content-state'].endAt, 0);
  assert.equal(ps[1].payload.aps['stale-date'], undefined);
});

test('stop ends the Live Activity only if there is one', () => {
  const idle = { phase: 'idle', tier: '', minutes: 0, running: false, endAt: null, left: 0, by: 'mac', at: now };
  assert.deepEqual(kinds(pushesFor(idle, red, [{ ...phone, activity: 'act' }], now)),
    ['phone:background:bg:apns', 'phone:liveactivity:end:activity']);
  assert.equal(pushesFor(idle, red, [{ ...phone, activity: 'act' }], now)[1].payload.aps['dismissal-date'], now);
  assert.deepEqual(kinds(pushesFor(idle, red, [phone], now)), ['phone:background:bg:apns']);
});

test('a new tomato replaces the old Live Activity', () => {
  const golden = { ...red, tier: 'Golden', minutes: 45, endAt: now + 2700, left: 2700 };
  assert.deepEqual(kinds(pushesFor(golden, red, [{ ...phone, activity: 'act' }], now)),
    ['phone:background:bg:apns', 'phone:liveactivity:end:activity', 'phone:liveactivity:start:pushToStart']);
  const ended = { ...red, endAt: now - 5 };  // the last one ran out, same tier again
  assert.deepEqual(kinds(pushesFor(red, ended, [{ ...phone, activity: 'act' }], now)),
    ['phone:background:bg:apns', 'phone:liveactivity:end:activity', 'phone:liveactivity:start:pushToStart']);
});

test('the device that made the change gets nothing; tokenless devices get nothing', () => {
  assert.deepEqual(kinds(pushesFor({ ...red, by: 'phone' }, null, [phone, mac], now)), []);
  assert.deepEqual(kinds(pushesFor(red, null, [{ id: 'w2', platform: 'watchos' }, { id: 'p2', platform: 'ios' }], now)), []);
});

test('a break and a debug build', () => {
  const rest = { ...red, phase: 'break', tier: 'Break', minutes: 5, endAt: now + 300, left: 300 };
  const ps = pushesFor(rest, red, [{ ...phone, env: 'development' }], now);
  assert.deepEqual(ps[1].payload.aps.alert, { title: '☕ Break', body: '5 min' });
  assert.ok(ps.every((p) => p.env === 'development'));
});

test('APNs token is a valid ES256 JWT for the team', async () => {
  const { jwt } = await import('./apns.js');
  const { generateKeyPairSync, verify } = await import('node:crypto');
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
  const t = jwt(privateKey.export({ type: 'pkcs8', format: 'pem' }), 'ABC123DEFG', now);
  const [h, b, s] = t.split('.');
  assert.deepEqual(JSON.parse(Buffer.from(h, 'base64url')), { alg: 'ES256', kid: 'ABC123DEFG' });
  assert.deepEqual(JSON.parse(Buffer.from(b, 'base64url')), { iss: '976B3SJZGY', iat: now });
  assert.ok(verify('sha256', Buffer.from(`${h}.${b}`), { key: publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(s, 'base64url')));
});
