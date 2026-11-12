// Sends one push to APNs over HTTP/2 with the team's .p8 key (token auth, ES256).
import http2 from 'node:http2';
import crypto from 'node:crypto';

const TEAM = '976B3SJZGY';
let cached = { token: '', at: 0 };

// APNs wants a fresh token at most every 20 min and rejects ones over 60 min old: renew after 50.
export function jwt(key, keyId, now = Math.floor(Date.now() / 1000)) {
  if (cached.token && now - cached.at < 3000) return cached.token;
  const part = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const unsigned = `${part({ alg: 'ES256', kid: keyId })}.${part({ iss: TEAM, iat: now })}`;
  const sig = crypto.sign('sha256', Buffer.from(unsigned), { key, dsaEncoding: 'ieee-p1363' }).toString('base64url');
  cached = { token: `${unsigned}.${sig}`, at: now };
  return cached.token;
}

export function send(push, key, keyId) {
  const host = push.env === 'development' ? 'https://api.sandbox.push.apple.com' : 'https://api.push.apple.com';
  return new Promise((resolve) => {
    const client = http2.connect(host);
    const done = (r) => { client.close(); resolve(r); };
    client.on('error', (e) => done({ status: 0, reason: String(e) }));
    const req = client.request({
      ':method': 'POST', ':path': `/3/device/${push.token}`, authorization: `bearer ${jwt(key, keyId)}`,
      'apns-topic': push.topic, 'apns-push-type': push.type, 'apns-priority': String(push.priority),
      'content-type': 'application/json',
    });
    let status = 0, body = '';
    req.setTimeout(10_000, () => { req.close(); done({ status: 0, reason: 'timeout' }); });
    req.on('response', (h) => { status = h[':status']; });
    req.on('data', (c) => { body += c; });
    req.on('end', () => { let reason = ''; try { reason = JSON.parse(body).reason; } catch {} done({ status, reason }); });
    req.on('error', (e) => done({ status: 0, reason: String(e) }));
    req.end(JSON.stringify(push.payload));
  });
}

// The token will never work again: forget it.
export const dead = (r) => r.status === 410 || (r.status === 400 && ['BadDeviceToken', 'DeviceTokenNotForTopic'].includes(r.reason));
