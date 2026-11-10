// Checks what `Tomatime --emulator --smoke` wrote. Reads the emulator as admin ("Bearer owner" skips rules).
// Usage: node tools/smoke.mjs <code>
if (process.argv[2] === 'deleted') {  // node tools/smoke.mjs deleted <uid> <gid>: the account is gone everywhere
  const [, , , uid, gid] = process.argv;
  const base = 'http://127.0.0.1:8181/v1/projects/demo-tomatime/databases/(default)/documents';
  const H = { Authorization: 'Bearer owner' };
  const gone = async (path) => (await fetch(`${base}/${path}`, { headers: H })).status === 404;
  const g = (await (await fetch(`${base}/groups/${gid}`, { headers: H })).json()).fields;
  const uids = g.memberUIDs.arrayValue.values?.map((v) => v.stringValue) ?? [];
  const auth = await (await fetch('http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1/projects/demo-tomatime/accounts:lookup',
    { method: 'POST', headers: { ...H, 'Content-Type': 'application/json' }, body: JSON.stringify({ localId: [uid] }) })).json();
  const problems = [
    !(await gone(`users/${uid}`)) && 'users doc still there',
    !(await gone(`groups/${gid}/members/${uid}`)) && 'member doc still there',
    uids.includes(uid) && 'still in memberUIDs',
    g.ownerUID.stringValue === uid && 'still the owner',
    auth.users?.length && 'auth account still there',
  ].filter(Boolean);
  if (problems.length) { console.error(`SMOKE CHECK FAILED (deleted): ${problems.join(', ')}`); process.exit(1); }
  console.log('smoke check ok (account deleted, Mina owns the group)');
  process.exit(0);
}
const code = process.argv[2];
const base = 'http://127.0.0.1:8181/v1/projects/demo-tomatime/databases/(default)/documents';
const get = async (path) => {
  const r = await fetch(`${base}/${path}`, { headers: { Authorization: 'Bearer owner' } });
  if (!r.ok) throw new Error(`${path}: HTTP ${r.status}`);
  return (await r.json()).fields;
};
const fail = (msg) => { console.error(`SMOKE CHECK FAILED: ${msg}`); process.exit(1); };
if (!/^TOMA-[23456789A-HJ-NP-Z]{6}$/.test(code ?? '')) fail(`bad or missing code: ${code}`);
const gid = (await get(`codes/${code}`)).groupID.stringValue;
const g = await get(`groups/${gid}`);
if (g.name.stringValue !== 'Smoke Group') fail(`group name ${g.name.stringValue}`);
const uids = g.memberUIDs.arrayValue.values.map((v) => v.stringValue);
if (uids.length !== 1 || g.ownerUID.stringValue !== uids[0]) fail('owner should be the only member');
const m = await get(`groups/${gid}/members/${uids[0]}`);
if (m.name.stringValue !== 'Smoke') fail(`member name ${m.name.stringValue}`);
const st = m.status.mapValue.fields;
if (st.state.stringValue !== 'focus' || st.tierName.stringValue !== 'Red' || !st.endsAt.timestampValue) fail('status not published');
console.log(`smoke check ok (${code} → ${gid})`);
