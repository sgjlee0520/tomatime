// Cloud Function: every change to a person's shared timer is pushed to their other iPhones and Watches.
import { onDocumentWritten } from 'firebase-functions/v2/firestore';
import { defineSecret } from 'firebase-functions/params';
import { initializeApp } from 'firebase-admin/app';
import { getFirestore, FieldValue } from 'firebase-admin/firestore';
import { pushesFor } from './push.js';
import { send, dead } from './apns.js';

initializeApp();
const APNS_KEY = defineSecret('APNS_KEY');        // contents of AuthKey_XXXXXXXXXX.p8
const APNS_KEY_ID = defineSecret('APNS_KEY_ID');  // its 10-character Key ID

export const timerPush = onDocumentWritten(
  { document: 'users/{uid}/timer/current', maxInstances: 5, secrets: [APNS_KEY, APNS_KEY_ID] },
  async (event) => {
    const s = event.data?.after?.data();
    if (!s) return;
    const db = getFirestore();
    const devices = await db.collection(`users/${event.params.uid}/devices`).get();
    const pushes = pushesFor(s, event.data.before?.data() ?? null, devices.docs.map((d) => ({ id: d.id, ...d.data() })),
      Math.floor(Date.now() / 1000));
    await Promise.all(pushes.map(async (p) => {
      const r = await send(p, APNS_KEY.value(), APNS_KEY_ID.value());
      if (r.status !== 200) console.warn('apns', p.deviceId, p.type, p.payload.aps.event ?? '', r.status, r.reason);
      // An ended Live Activity's token is spent; a new one arrives from the phone. Clear it only if unchanged.
      const spent = p.payload.aps.event === 'end';
      if (dead(r) || spent) {
        const ref = db.doc(`users/${event.params.uid}/devices/${p.deviceId}`);
        await db.runTransaction(async (tx) => {
          if ((await tx.get(ref)).get(p.field) === p.token) tx.update(ref, { [p.field]: FieldValue.delete() });
        });
      }
    }));
  },
);
