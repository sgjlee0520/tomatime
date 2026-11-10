// Plays Mina and Alex for a hands-on walk-through against the local emulators (auth 9099, firestore 8181).
// Waits for the first group you make, then: both join; Mina is focusing, Alex is on a break; a minute later
// Mina starts a 1-minute group tomato. Mina also joins every group tomato you start, and when you pick
// the group break, the next round starts 12 s later instead of after 10 minutes.
// Usage (emulators running): node tools/friends.mjs
import { execFileSync } from 'node:child_process';
import { initializeApp } from 'firebase/app';
import { getAuth, connectAuthEmulator, signInWithEmailAndPassword } from 'firebase/auth';
import { getFirestore, connectFirestoreEmulator, doc, getDoc, onSnapshot, updateDoc, arrayUnion } from 'firebase/firestore';

const REST = 'http://127.0.0.1:8181/v1/projects/demo-tomatime/databases/(default)/documents';
const sleep = ms => new Promise(r => setTimeout(r, ms));
const fake = (...a) => console.log(execFileSync('node', [new URL('./fake-member.mjs', import.meta.url).pathname, ...a]).toString().trim());

let code;
console.log('waiting for a group…');
while (!code) {
  const r = await fetch(`${REST}/codes`, { headers: { Authorization: 'Bearer owner' } }).then(r => r.json()).catch(() => ({}));
  code = r.documents?.[0]?.name.split('/').pop();
  if (!code) await sleep(1000);
}
console.log('group code', code);
fake('join', code, 'Mina'); fake('status', code, 'Mina', 'focus', 'Golden', '45');
fake('join', code, 'Alex'); fake('status', code, 'Alex', 'break', '', '4');
setTimeout(() => fake('start', code, 'Mina', 'Red', '1'), 60_000);

const app = initializeApp({ projectId: 'demo-tomatime', apiKey: 'fake-api-key' });
const auth = getAuth(app);
connectAuthEmulator(auth, 'http://127.0.0.1:9099', { disableWarnings: true });
const db = getFirestore(app);
connectFirestoreEmulator(db, '127.0.0.1', 8181);
const mina = (await signInWithEmailAndPassword(auth, 'mina@fake.tomatime', 'password123')).user.uid;
const gid = (await getDoc(doc(db, 'codes', code))).data().groupID;
const advanced = new Set();
onSnapshot(doc(db, 'groups', gid, 'sessions', 'current'), snap => {
  const s = snap.data();
  if (!s) return;
  const startAt = s.startAt?.toDate() ?? new Date((s.createdAt?.toDate() ?? new Date()).getTime() + 10_000);
  if (s.startedBy !== mina && !s.joined.includes(mina) && startAt > new Date() && !s.cancelled) {
    console.log('Mina joins round', s.round);
    updateDoc(snap.ref, { joined: arrayUnion(mina), [`devices.${mina}`]: 'fake' });
  }
  if (s.nextJoined?.some(u => u !== mina) && !advanced.has(s.id)) {
    advanced.add(s.id);
    console.log('you picked the group break: next round in 3 + 12 s');
    setTimeout(() => fake('next', code), 3000);
  }
});
