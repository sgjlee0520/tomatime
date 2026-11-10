// Checks what `Tomatime --emulator --smoke` wrote. Reads the emulator as admin ("Bearer owner" skips rules).
// Usage: node tools/smoke.mjs <code>
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
