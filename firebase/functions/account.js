// "Delete Account" from the iPhone (App Store 5.1.1(v)): leave every group, delete the person's data and their
// sign-in. The Mac does the same on the device (GroupStore.deleteAccount); the iPhone asks this function.
import { getAuth } from 'firebase-admin/auth';
import { getFirestore } from 'firebase-admin/firestore';

// What leaving does to one group (same as GroupStore.leave): the last one out deletes it and its invite code;
// an owner hands it to the member who joined first.
export function leavePlan(group, members, uid) {
  const others = group.memberUIDs.filter((u) => u !== uid);
  if (others.length === 0) return { deleteGroup: true, code: group.code };
  const update = { memberUIDs: others };
  if (group.ownerUID === uid) {
    const byJoin = members.filter((x) => others.includes(x.uid)).sort((a, b) => a.joinedAt - b.joinedAt);
    update.ownerUID = byJoin[0]?.uid ?? others[0];
  }
  return { update };
}

export async function deleteAccount(req, res) {
  let uid;
  try {
    uid = (await getAuth().verifyIdToken((req.get('authorization') ?? '').replace(/^Bearer /, ''))).uid;
  } catch {
    res.status(401).json({ error: 'Please sign in again.' });
    return;
  }
  const db = getFirestore();
  const groups = await db.collection('groups').where('memberUIDs', 'array-contains', uid).get();
  for (const doc of groups.docs) {
    const empty = await db.runTransaction(async (tx) => {
      const group = (await tx.get(doc.ref)).data();
      if (!group) return false;
      const members = (await tx.get(doc.ref.collection('members'))).docs
        .map((m) => ({ uid: m.id, joinedAt: m.get('joinedAt')?.toMillis?.() ?? 0 }));
      const plan = leavePlan(group, members, uid);
      if (plan.deleteGroup) {
        if (plan.code) tx.delete(db.doc(`codes/${plan.code}`));
      } else {
        tx.update(doc.ref, plan.update);
        tx.delete(doc.ref.collection('members').doc(uid));
      }
      return !!plan.deleteGroup;
    });
    if (empty) await db.recursiveDelete(doc.ref);  // the group, its members and sessions
  }
  await db.recursiveDelete(db.doc(`users/${uid}`));  // name, shared timer, device push tokens
  await getAuth().deleteUser(uid);
  res.json({ deleted: true });
}
