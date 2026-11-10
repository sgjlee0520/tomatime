// A pretend group member for testing against the local emulators (auth 9099, firestore 8181).
// Usage: node tools/fake-member.mjs <join|status|start|leave> <code> [args]
//   join <code> <name>                      status <code> <name> <focus|break|idle> <tier> <minutes>
//   start <code> <name> <tier> <minutes>    leave <code> <name>
//   next <code>   (skip the 10-minute group break: the next round starts in 12 s, for those who picked it)
import { initializeApp } from 'firebase/app';
import { getAuth, connectAuthEmulator, signInWithEmailAndPassword, createUserWithEmailAndPassword } from 'firebase/auth';
import { getFirestore, connectFirestoreEmulator, doc, getDoc, writeBatch, updateDoc, setDoc,
         arrayUnion, arrayRemove, deleteDoc, serverTimestamp } from 'firebase/firestore';

const [cmd, rawCode, name = 'Mina', ...rest] = process.argv.slice(2);
const code = rawCode?.toUpperCase().startsWith('TOMA-') ? rawCode.toUpperCase() : `TOMA-${rawCode?.toUpperCase()}`;
const app = initializeApp({ projectId: 'demo-tomatime', apiKey: 'fake-api-key' });
const auth = getAuth(app);
connectAuthEmulator(auth, 'http://127.0.0.1:9099', { disableWarnings: true });
const db = getFirestore(app);
connectFirestoreEmulator(db, '127.0.0.1', 8181);

// Same name → same account while the emulator runs.
const email = `${name.toLowerCase()}@fake.tomatime`;
const cred = await signInWithEmailAndPassword(auth, email, 'password123')
  .catch(() => createUserWithEmailAndPassword(auth, email, 'password123'));
const uid = cred.user.uid;
const codeDoc = await getDoc(doc(db, 'codes', code));
if (!codeDoc.exists()) { console.error(`no group with code ${code}`); process.exit(1); }
const gid = codeDoc.data().groupID;
const me = doc(db, 'groups', gid, 'members', uid);

if (cmd === 'join') {
  const b = writeBatch(db);
  b.update(doc(db, 'groups', gid), { memberUIDs: arrayUnion(uid) });
  b.set(me, { name, joinedAt: serverTimestamp(), hasPass: false, secondsByDevice: {}, joinCode: code,
              status: { state: 'idle', tierName: '', minutes: 0, endsAt: null, sessionID: null } });
  await b.commit();
} else if (cmd === 'status') {
  const [state, tierName = 'Red', minutes = '25'] = rest;
  const endsAt = state === 'idle' ? null : new Date(Date.now() + Number(minutes) * 60000);
  await updateDoc(me, { status: { state, tierName, minutes: Number(minutes), endsAt, sessionID: null } });
} else if (cmd === 'start') {
  const [tierName = 'Red', minutes = '25'] = rest;
  await setDoc(doc(db, 'groups', gid, 'sessions', 'current'), {
    id: crypto.randomUUID(), round: 1, startedBy: uid, starterName: name, tierName, minutes: Number(minutes),
    createdAt: serverTimestamp(), cancelled: false, joined: [uid], nextJoined: [], devices: { [uid]: 'fake' } });
} else if (cmd === 'next') {
  const ref = doc(db, 'groups', gid, 'sessions', 'current');
  const s = (await getDoc(ref)).data();
  await updateDoc(ref, { round: s.round + 1, startAt: new Date(Date.now() + 12000), joined: s.nextJoined ?? [],
                         nextJoined: [], id: crypto.randomUUID() });
} else if (cmd === 'leave') {
  const b = writeBatch(db);
  b.update(doc(db, 'groups', gid), { memberUIDs: arrayRemove(uid) });
  b.delete(me);
  await b.commit();
} else { console.error('unknown command'); process.exit(2); }
console.log(`${name} ${cmd} ok (group ${gid})`);
process.exit(0);
