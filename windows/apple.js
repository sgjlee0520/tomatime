// Sign in with Apple from a PC, in the person's own browser (never a password typed into this app):
// 1. the browser opens Apple's sign-in page (signInURL);
// 2. Apple sends the browser to our web page (site: signin.html), which hands the answer to this PC only:
//    http://127.0.0.1:<port>/ , a tiny server that lives for this one sign-in (waitForToken);
// 3. Firebase checks the token and the nonce (store.signInWithApple) and signs in the same account as on the
//    person's iPhone, Watch and Mac.
// Needs a Services ID at Apple (clientId) with the web page as its Return URL, named in the Firebase console.
import http from 'node:http';
import { createHash, randomUUID } from 'node:crypto';

export const newNonce = () => randomUUID() + randomUUID();

export function signInURL({ clientId, redirect, port, state, rawNonce }) {
  return 'https://appleid.apple.com/auth/authorize?' + new URLSearchParams({
    client_id: clientId, redirect_uri: redirect, response_type: 'code id_token', response_mode: 'fragment',
    nonce: createHash('sha256').update(rawNonce).digest('hex'), state: `${port}.${state}` });  // no scope: no email, no name
}

const page = (text) => `<!doctype html><meta charset="utf-8"><title>Tomatime</title>
<body style="font:1.1rem system-ui;max-width:28rem;margin:20vh auto;padding:0 1rem;text-align:center"><p id="t">${text}</p>`;
const handOver = page('Signing in…') + `<script>
fetch('/token', { method: 'POST', body: location.hash.slice(1) }).then((r) => r.text()).then((t) => { document.getElementById('t').textContent = t; });
history.replaceState(null, '', '/');
</script>`;

// Resolves with Apple's id token once the browser hands it over; rejects on cancel, a wrong state, or after 5 minutes.
export function waitForToken(state, timeoutMs = 300_000) {
  let finish;
  const token = new Promise((resolve, reject) => { finish = { resolve, reject }; });
  const server = http.createServer((req, res) => {
    if (req.method === 'GET') return res.writeHead(200, { 'content-type': 'text/html' }).end(handOver);
    let body = '';
    req.on('data', (chunk) => { if (body.length < 20_000) body += chunk; });
    req.on('end', () => {
      const p = new URLSearchParams(body), ok = p.get('state')?.split('.')[1] === state && !!p.get('id_token');
      res.writeHead(ok ? 200 : 400, { 'content-type': 'text/plain; charset=utf-8' })
        .end(ok ? 'You’re signed in. You can close this tab and go back to Tomatime.' : 'Sign-in didn’t finish. Close this tab and try again from Tomatime.');
      if (ok) finish.resolve(p.get('id_token'));
      else if (p.get('state')?.split('.')[1] === state) finish.reject(new Error(p.get('error') ?? 'no token'));
    });
  });
  const timer = setTimeout(() => finish.reject(new Error('timeout')), timeoutMs);
  const ready = new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server.address().port)));
  const close = () => { clearTimeout(timer); server.close(); server.closeAllConnections?.(); };
  token.then(close, close);
  return { ready, token, cancel: () => finish.reject(new Error('cancelled')) };
}
