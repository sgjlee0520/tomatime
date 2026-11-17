// Tomatime Groups on Firebase, ported from Groups/GroupStore.swift: sign-in, live listeners and writes.
// It writes exactly what the Mac app writes (data model and security rules: firebase/firestore.rules).
// No Electron here, so core.test.js can run it in plain Node against the local emulators.
import { initializeApp } from '@firebase/app';
import { initializeAuth, connectAuthEmulator, onAuthStateChanged, signInAnonymously, signInWithCredential,
  OAuthProvider, signOut, deleteUser } from '@firebase/auth';
import { getFirestore, connectFirestoreEmulator, doc, collection, query, where, onSnapshot, getDoc, getDocFromServer,
  getDocs, setDoc, updateDoc, deleteDoc, writeBatch, runTransaction, serverTimestamp, arrayUnion, arrayRemove,
  FieldPath, deleteField } from '@firebase/firestore';
import { GroupError, withTimeout, plain, member, session, statusData, idleStatus, secondsSince, canStartSession,
  makeInviteCode, normalizeCode, timerFrom, groupsFree, nextTomato, sessionPhase } from './rules.js';

const isDenied = (e) => e?.code === 'permission-denied';
const quiet = (p) => p.catch(() => {});  // fire-and-forget writes: Firestore retries them itself when back online

export class GroupStore {
  uid = null;
  myName = null;
  groups = [];
  sessions = {};          // by group id
  onChange = () => {};
  onTimer = () => {};     // the shared Mac/iPhone/Watch/PC timer changed
  #meta = {}; #members = {}; #codes = {}; #stops = {}; #stopMine = [];

  // config: the Firebase web config, or null for the local emulators. persistence: where the sign-in is kept
  // between launches (main.js: a file; tests: nothing).
  constructor({ config, persistence, deviceKey }) {
    this.deviceKey = deviceKey;
    const app = initializeApp(config ?? { projectId: 'demo-tomatime', apiKey: 'fake-api-key' }, `tomatime-${deviceKey}`);
    this.auth = initializeAuth(app, persistence ? { persistence } : {});
    this.db = getFirestore(app);
    if (!config) {
      connectAuthEmulator(this.auth, 'http://127.0.0.1:9099', { disableWarnings: true });
      connectFirestoreEmulator(this.db, '127.0.0.1', 8181);  // not 8080: a web filter on the dev Mac intercepts it
    }
  }

  get signedIn() { return this.uid != null; }
  get anonymous() { return this.auth.currentUser?.isAnonymous === true; }
  code(gid) { return this.#codes[gid]; }

  // Resolves once the saved sign-in (if any) is loaded.
  start() {
    onAuthStateChanged(this.auth, (user) => this.#userChanged(user?.uid ?? null));
    return this.auth.authStateReady();
  }

  #userChanged(uid) {
    if (uid === this.uid) return;
    this.#stopListening();
    this.uid = uid;
    this.myName = null;
    if (!uid) return this.onChange();
    quiet(getDoc(doc(this.db, 'users', uid)).then((snap) => {
      if (this.uid === uid) { this.myName = snap.data()?.name ?? null; this.onChange(); }
    }));
    this.#stopMine = [
      onSnapshot(doc(this.db, 'users', uid, 'timer', 'current'), (snap) => {
        const s = snap.metadata.hasPendingWrites ? null : timerFrom(snap.data());
        if (s) this.onTimer(s);
      }, () => {}),
      // includeMetadataChanges: also hear "now saved on the server"
      onSnapshot(query(collection(this.db, 'groups'), where('memberUIDs', 'array-contains', uid)),
        { includeMetadataChanges: true }, (snap) => this.#groupsArrived(snap.docs), () => {}),
    ];
  }

  #stopListening() {
    [...this.#stopMine, ...Object.values(this.#stops).flat()].forEach((stop) => stop());
    this.#stopMine = []; this.#stops = {}; this.#meta = {}; this.#members = {}; this.#codes = {};
    this.sessions = {}; this.groups = [];
  }

  #groupsArrived(docs) {
    const ids = new Set(docs.map((d) => d.id));
    for (const gone of Object.keys(this.#stops).filter((id) => !ids.has(id))) {
      this.#stops[gone].forEach((stop) => stop());
      for (const map of [this.#stops, this.#meta, this.#members, this.#codes, this.sessions]) delete map[gone];
    }
    for (const d of docs) {
      const x = d.data();
      this.#meta[d.id] = { id: d.id, name: x.name ?? 'Group', ownerUID: x.ownerUID ?? '', memberUIDs: x.memberUIDs ?? [],
        unlocked: x.unlocked === true, members: [] };
      this.#codes[d.id] = x.code;
      // Only once the server has the group: the rules refuse earlier listens, and a refused listener stops for good.
      if (!this.#stops[d.id] && !d.metadata.hasPendingWrites) this.#listen(d.id);
    }
    this.#rebuild();
  }

  #listen(gid) {
    const estimate = { serverTimestamps: 'estimate' };
    this.#stops[gid] = [
      onSnapshot(collection(this.db, 'groups', gid, 'members'), (snap) => {
        this.#members[gid] = snap.docs.map((d) => member(d.id, plain(d.data(estimate)))).filter(Boolean);
        this.#rebuild();
      }, () => {}),
      onSnapshot(this.#sessionDoc(gid), (snap) => {
        const s = snap.exists() ? session(plain(snap.data(estimate))) : null;
        if (s) this.sessions[gid] = s; else delete this.sessions[gid];
        this.#rebuild();
      }, () => {}),
    ];
  }

  #rebuild() {
    this.groups = Object.values(this.#meta).map((g) => ({ ...g,
      members: (this.#members[g.id] ?? []).filter((m) => g.memberUIDs.includes(m.uid)).sort((a, b) => a.joinedAt - b.joinedAt),
    })).sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true }));
    this.onChange();
  }

  // MARK: Signing in

  // Invite code + name is all a member needs: no account to make, no password.
  async signInWithCode() {
    await withTimeout(() => signInAnonymously(this.auth));
    this.#userChanged(this.auth.currentUser?.uid ?? null);
  }

  // The same account as on the person's iPhone, Watch and Mac. idToken: from Apple; rawNonce: what its nonce hashes.
  async signInWithApple(idToken, rawNonce) {
    await withTimeout(() => signInWithCredential(this.auth, new OAuthProvider('apple.com').credential({ idToken, rawNonce })));
    this.#userChanged(this.auth.currentUser?.uid ?? null);
  }

  signOut() { return signOut(this.auth); }  // the state listener clears everything

  // Code sign-ins only (GroupStore.deleteAccount, codeSignIn path): leaves every group, deletes the name and the
  // sign-in. An Apple account is deleted from the iPhone or Mac app, which also tells Apple.
  async deleteAccount() {
    const user = this.auth.currentUser, uid = this.uid;
    if (!user || !uid) throw new GroupError('notSignedIn');
    await this.#online();
    for (const g of [...this.groups]) await this.leave(g.id);
    const devices = await withTimeout(() => getDocs(collection(this.db, 'users', uid, 'devices')));
    for (const d of devices.docs) await withTimeout(() => deleteDoc(d.ref));
    await withTimeout(() => deleteDoc(doc(this.db, 'users', uid, 'timer', 'current')));
    await withTimeout(() => deleteDoc(doc(this.db, 'users', uid)));
    // A sign-in too old to delete itself is signed out instead: its data is already gone.
    await withTimeout(() => deleteUser(user).catch(() => signOut(this.auth)));
  }

  // The shared timer. Queued while offline; Firestore sends it when it can.
  writeTimer(t) {
    if (this.uid) quiet(setDoc(doc(this.db, 'users', this.uid, 'timer', 'current'), t));
  }

  // MARK: Groups

  async loadName() {
    if (this.myName == null && this.uid) {
      const snap = await withTimeout(() => getDoc(doc(this.db, 'users', this.uid))).catch(() => null);
      this.myName = snap?.data()?.name ?? null;
    }
    return this.myName;
  }

  async setName(name) {
    if (!this.uid) throw new GroupError('notSignedIn');
    await this.#online();
    const batch = writeBatch(this.db);
    batch.set(doc(this.db, 'users', this.uid), { name });
    for (const g of this.groups) batch.update(this.#memberDoc(g.id), { name });
    await withTimeout(() => batch.commit());
    this.myName = name;
    this.onChange();
  }

  async createGroup(name, unlocked = groupsFree) {
    if (!this.uid || !this.myName) throw new GroupError('notSignedIn');
    await this.#online();
    for (let i = 0; i < 3; i++) {  // a taken code makes the batch fail; try a fresh one
      const code = makeInviteCode(), g = doc(collection(this.db, 'groups')), batch = writeBatch(this.db);
      batch.set(g, { name, code, ownerUID: this.uid, memberUIDs: [this.uid], unlocked, createdAt: serverTimestamp() });
      batch.set(doc(g, 'members', this.uid), this.#newMember(this.myName, null));
      batch.set(doc(this.db, 'codes', code), { groupID: g.id });
      try {
        await withTimeout(() => batch.commit());
        return code;
      } catch (e) { if (!isDenied(e)) throw e; }
    }
    throw new GroupError('notAllowed');
  }

  // Non-members can't read a group, so a refused join after a valid code means the group is full.
  // Returns 'ok' | 'alreadyMember' | 'full'.
  async join(typed, hasPass = groupsFree) {
    if (!this.uid || !this.myName) throw new GroupError('notSignedIn');
    const code = normalizeCode(typed);
    if (!code) throw new GroupError('noSuchCode');
    await this.#online();
    const snap = await withTimeout(() => getDoc(doc(this.db, 'codes', code)));
    const gid = snap.data()?.groupID;
    if (!gid) throw new GroupError('noSuchCode');
    if (this.groups.some((g) => g.id === gid)) return 'alreadyMember';
    const batch = writeBatch(this.db);
    batch.update(doc(this.db, 'groups', gid), { memberUIDs: arrayUnion(this.uid) });
    batch.set(doc(this.db, 'groups', gid, 'members', this.uid), { ...this.#newMember(this.myName, code), hasPass });
    try {
      await withTimeout(() => batch.commit());
      return 'ok';
    } catch (e) { if (isDenied(e)) return 'full'; throw e; }
  }

  async leave(gid) {
    const g = this.groups.find((x) => x.id === gid);
    if (!this.uid || !g) throw new GroupError('notSignedIn');
    await this.#online();
    const batch = writeBatch(this.db), others = g.members.filter((m) => m.uid !== this.uid);
    if (g.memberUIDs.length === 1 && g.memberUIDs[0] === this.uid) {  // last one out deletes the group and its code
      batch.delete(this.#memberDoc(gid));
      batch.delete(doc(this.db, 'groups', gid));
      if (this.#codes[gid]) batch.delete(doc(this.db, 'codes', this.#codes[gid]));
    } else {
      const update = { memberUIDs: arrayRemove(this.uid) };
      if (g.ownerUID === this.uid && others.length) update.ownerUID = others[0].uid;  // members are sorted by joinedAt
      batch.update(doc(this.db, 'groups', gid), update);
      batch.delete(this.#memberDoc(gid));
    }
    await withTimeout(() => batch.commit());
  }

  async remove(other, gid) {
    await this.#online();
    const batch = writeBatch(this.db);
    batch.update(doc(this.db, 'groups', gid), { memberUIDs: arrayRemove(other) });
    batch.delete(doc(this.db, 'groups', gid, 'members', other));
    await withTimeout(() => batch.commit());
  }

  async newCode(gid) {
    await this.#online();
    const code = makeInviteCode(), batch = writeBatch(this.db);
    batch.update(doc(this.db, 'groups', gid), { code });
    batch.set(doc(this.db, 'codes', code), { groupID: gid });
    if (this.#codes[gid]) batch.delete(doc(this.db, 'codes', this.#codes[gid]));
    await withTimeout(() => batch.commit());
    return code;
  }

  async rename(gid, name) {
    await this.#online();
    await withTimeout(() => updateDoc(doc(this.db, 'groups', gid), { name }));
  }

  // MARK: Live status and minutes (fire-and-forget: they catch up when back online)

  publish(status) {
    for (const g of this.groups) quiet(updateDoc(this.#memberDoc(g.id), { status: statusData(status) }));
  }

  // Only this PC's own minutes, and only from the day you joined.
  publishSeconds(device, local) {
    for (const g of this.groups) {
      const joined = g.members.find((m) => m.uid === this.uid)?.joinedAt;
      if (joined != null) quiet(updateDoc(this.#memberDoc(g.id), new FieldPath('secondsByDevice', device), secondsSince(local, joined)));
    }
  }

  // MARK: Group tomatoes

  // Refused (busy) while a group tomato or a group break is on: it would wipe it out for the others.
  // `plan`: Exam mode (focus, break, focus, …); its first tomato is `minutes`.
  async startSession(gid, tierName, minutes, plan = []) {
    if (!this.uid) throw new GroupError('notSignedIn');
    await this.#online();
    const ref = this.#sessionDoc(gid), uid = this.uid;
    await this.#transact(async (tx) => {
      const snap = await tx.get(ref);
      if (!canStartSession(snap.exists() ? session(plain(snap.data())) : null, Date.now())) throw new GroupError('busy');
      tx.set(ref, { id: crypto.randomUUID(), round: 1, startedBy: uid, starterName: this.myName ?? '', tierName, minutes,
        createdAt: serverTimestamp(), cancelled: false, joined: [uid], nextJoined: [], devices: { [uid]: this.deviceKey },
        ...(plan.length ? { plan } : {}) });
    });
  }

  // Joining also claims the tomato for this PC: my other devices see `devices` and stand down.
  // Only for round `sid`: a click that lands after that round was replaced or moved on changes nothing.
  setJoined(gid, sid, on) { return this.#optIn(gid, sid, 'joined', on); }
  setNextJoined(gid, sid, on) { return this.#optIn(gid, sid, 'nextJoined', on); }

  #optIn(gid, sid, list, on) {
    const uid = this.uid, ref = this.#sessionDoc(gid);
    if (!uid) return Promise.resolve();
    return quiet(this.#transact(async (tx) => {
      if ((await tx.get(ref)).data()?.id !== sid) return;
      if (on) tx.update(ref, list, arrayUnion(uid), new FieldPath('devices', uid), this.deviceKey);
      else tx.update(ref, list, arrayRemove(uid));
    }));
  }

  // Everyone opted in computes the same next start, so racing callers write the same thing; only the first counts.
  advanceRound(gid, round, startAt) {
    const ref = this.#sessionDoc(gid);
    return quiet(runTransaction(this.db, async (tx) => {
      const d = (await tx.get(ref)).data();
      if (d?.round !== round) return;
      const s = session(plain(d)), t = s && nextTomato(s);  // the tomato picked during the break, or the plan's
      // Its tomato was made longer after this PC went on the break: it isn't over, nothing moves on.
      if (s && sessionPhase(s, Date.now()).kind !== 'over') return;
      tx.update(ref, { round: round + 1, startAt: new Date(startAt), joined: d.nextJoined ?? [], nextJoined: [], id: crypto.randomUUID(),
        ...(t ? { tierName: t.name, minutes: t.minutes, nextTierName: deleteField(), nextMinutes: deleteField(), nextRound: deleteField() } : {}) });
    }));
  }

  // Anyone in it: this group tomato's length while it runs, or (`next`) the next round's, during the group break.
  setTomato(gid, sid, tierName, minutes, next) {
    const ref = this.#sessionDoc(gid);
    return quiet(this.#transact(async (tx) => {
      const d = (await tx.get(ref)).data();
      if (d?.id !== sid) return;
      tx.update(ref, next ? { nextTierName: tierName, nextMinutes: minutes, nextRound: (d.round ?? 1) + 1 }
        : { tierName, minutes, nextTierName: deleteField(), nextMinutes: deleteField(), nextRound: deleteField() });
    }));
  }

  cancelSession(gid, sid) {
    const ref = this.#sessionDoc(gid);
    return quiet(this.#transact(async (tx) => {
      if ((await tx.get(ref)).data()?.id === sid) tx.update(ref, { cancelled: true });
    }));
  }

  // MARK: Helpers

  // User actions check the server first. Otherwise Firestore applies a write locally and sends it whenever the
  // network is back, long after the person gave up.
  async #online() {
    if (!this.uid) throw new GroupError('notSignedIn');
    await withTimeout(() => getDocFromServer(doc(this.db, 'users', this.uid)), 5);
  }

  // Each attempt checks a deadline, so a retry after an outage can't land long after the user gave up.
  #transact(body) {
    const deadline = Date.now() + 8000;
    return withTimeout(() => runTransaction(this.db, (tx) => {
      if (Date.now() >= deadline) throw new GroupError('offline');
      return body(tx);
    }));
  }

  #memberDoc(gid) { return doc(this.db, 'groups', gid, 'members', this.uid ?? '-'); }
  #sessionDoc(gid) { return doc(this.db, 'groups', gid, 'sessions', 'current'); }

  #newMember(name, joinCode) {
    return { name, joinedAt: serverTimestamp(), hasPass: groupsFree, status: statusData(idleStatus), secondsByDevice: {},
      ...(joinCode ? { joinCode } : {}) };
  }
}
