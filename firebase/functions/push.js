// Which APNs pushes a change to the shared timer (users/{uid}/timer/current, see Shared/TomatoTimer.swift)
// sends to a person's other devices. Pure: index.js sends them.
const APP = 'com.sgjlee.tomatime';
const WATCH = 'com.sgjlee.tomatime.watchkitapp';

// Shared/TomatoActivity.swift ContentState; endAt is unix seconds, 0 while paused.
export const contentState = (s) =>
  ({ phase: s.phase, tier: s.tier, minutes: s.minutes, running: s.running, endAt: s.endAt ?? 0, left: s.left });

const alert = (s) => s.phase === 'break'
  ? { title: '☕ Break', body: `${Math.round(s.minutes)} min` }
  : { title: `🍅 ${s.tier} tomato`, body: s.running ? `${Math.round(s.minutes)} min focus` : 'Paused' };

// A different tomato (or break) from the one the Live Activity shows: replace it rather than update it.
const newSession = (s, prev, now) => !prev || prev.phase !== s.phase || prev.tier !== s.tier ||
  prev.minutes !== s.minutes || (prev.running && prev.endAt != null && prev.endAt <= now);

export function pushesFor(s, prev, devices, now) {
  const out = [];
  for (const d of devices) {
    if (d.id === s.by) continue;  // it made the change, and starts its own Live Activity
    const env = d.env === 'development' ? 'development' : 'production';
    const push = (field, topic, type, priority, payload) =>
      out.push({ deviceId: d.id, field, token: d[field], env, topic, type, priority, payload });
    const background = (topic) => push('apns', topic, 'background', 5, { aps: { 'content-available': 1 }, timer: s });
    const live = (field, aps) => push(field, `${APP}.push-type.liveactivity`, 'liveactivity', 10,
      { aps: { timestamp: now, 'content-state': contentState(s), ...aps } });

    if (d.platform === 'watchos') {
      if (d.apns) background(WATCH);
    } else if (d.platform === 'ios') {
      if (d.apns) background(APP);
      const stale = s.running && s.endAt ? { 'stale-date': Math.ceil(s.endAt) } : {};
      if (s.phase === 'idle') {
        if (d.activity) live('activity', { event: 'end', 'dismissal-date': now });
      } else if (d.activity && !newSession(s, prev, now)) {
        live('activity', { event: 'update', ...stale });
      } else {
        if (d.activity) live('activity', { event: 'end', 'dismissal-date': now });
        if (d.pushToStart) live('pushToStart', { event: 'start', 'attributes-type': 'TomatoActivity', attributes: {},
          alert: alert(s), 'input-push-token': 1, ...stale });
      }
    }
  }
  return out;
}
