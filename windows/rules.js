// Group tomato rules and the shared timer, ported 1:1 from Groups/GroupRules.swift and Shared/TomatoTimer.swift.
// Plain values and decisions: no Firebase, no Electron, so `node --test` can check them (rules.test.js mirrors
// Tests/RulesCheck.swift). Times are milliseconds since 1970, except the shared timer's fields (unix seconds,
// as stored). When a rule changes in the Swift file, change it here too.

export const maxGroupSize = 6, countdownSeconds = 10, groupBreakMinutes = 10, activeSeconds = 120;
export const groupsFree = true;       // GroupRules.swift groupsFree
export const maxFocusMinutes = 480;   // main.swift maxFocusMinutes
export const tiers = [
  { name: 'Green', minutes: 20, color: '#73c740' },
  { name: 'Red', minutes: 25, color: '#e63326' },
  { name: 'Golden', minutes: 45, color: '#ffc21a' },
  { name: 'Diamond', minutes: 60, color: '#8ce0ff' },
];
// A tomato's color: its tier's, or for a typed length the biggest tier it reaches (30 min = red, 50 = golden).
export const tierColor = (name, minutes) =>
  (tiers.find((t) => t.name === name) ?? tiers.findLast((t) => t.minutes <= minutes) ?? tiers[0]).color;

const startOfDay = (ms) => { const d = new Date(ms); return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime(); };

// Local calendar day, e.g. "2026-11-9" (no zero padding, Gregorian: what the Mac writes).
export function dayKey(ms = Date.now()) {
  const d = new Date(ms);
  return `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()}`;
}

export function joinVerdict(g, uid, hasPass) {
  if (g.memberUIDs.includes(uid)) return 'alreadyMember';
  if (g.memberUIDs.length >= maxGroupSize) return 'full';
  return g.unlocked || hasPass ? 'ok' : 'needsPass';
}

// status: { state: 'focus' | 'break' | 'idle', tierName, minutes, endsAt (ms or null), sessionID }
export function effectiveState(s, now) {
  return s.state !== 'idle' && s.endsAt != null && s.endsAt <= now ? 'idle' : s.state;
}

export function friendsFocusing(groups, me, now) {
  return new Set(groups.flatMap((g) => g.members)
    .filter((m) => m.uid !== me && effectiveState(m.status, now) === 'focus').map((m) => m.uid)).size;
}

// Minutes shown anywhere: whole minutes done, forgiving half a second (a finished tomato tallies a few ms short).
export const wholeMinutes = (seconds) => Math.floor((seconds + 0.5) / 60);

export function statusText(m, now) {
  const left = Math.ceil(((m.status.endsAt ?? now) - now) / 60000);
  switch (effectiveState(m.status, now)) {
    case 'focus': return `${m.status.tierName} · ${left} min`;
    case 'break': return `break · ${left} min`;
    default: return `${wholeMinutes(memberSeconds(m, now))} min today`;
  }
}

export function memberSeconds(m, day) {
  if (startOfDay(day) < startOfDay(m.joinedAt)) return 0;
  const key = dayKey(day);
  return Object.values(m.secondsByDevice).reduce((sum, days) => sum + (days[key] ?? 0), 0);
}

export const groupDayMinutes = (g, days) =>
  days.map((day) => g.members.reduce((sum, m) => sum + wholeMinutes(memberSeconds(m, day)), 0));

const ranked = (rows) => rows.sort((a, b) => b.minutes - a.minutes || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));

export const dayRanking = (g, day) =>
  ranked(g.members.map((m) => ({ name: m.name, minutes: wholeMinutes(memberSeconds(m, day)) })));

// firstWeekday: 0 = Sunday … 6 = Saturday (the PC's own setting).
export function weeklyRanking(g, now, firstWeekday) {
  const d = new Date(now), back = (d.getDay() - firstWeekday + 7) % 7;
  const days = [...Array(7)].map((_, i) => new Date(d.getFullYear(), d.getMonth(), d.getDate() - back + i).getTime());
  return ranked(g.members.map((m) =>
    ({ name: m.name, minutes: days.reduce((sum, day) => sum + wholeMinutes(memberSeconds(m, day)), 0) })));
}

// { kind: 'countdown', seconds } | { kind: 'running', left (seconds) } | { kind: 'over' }
export function sessionPhase(s, now) {
  if (s.cancelled) return { kind: 'over' };
  const toStart = (s.startAt - now) / 1000;
  if (toStart > 0) return { kind: 'countdown', seconds: Math.ceil(toStart) };
  const left = s.minutes * 60 + toStart;
  return left > 0 ? { kind: 'running', left } : { kind: 'over' };
}

export const sessionEnd = (s) => s.startAt + s.minutes * 60000;

// Exam mode: a plan of tomatoes and breaks run back to back, solo or as a group; people can type their own.
// The recommended one and the studies behind it: docs/exam-mode-science.md.
export const recommendedExamPlan = [25, 8, 60, 10, 45, 20, 45];
export const examDoneText = 'Go take a walk.';
export const examName = '📝 Exam mode';  // how menus, the countdown and the red screen name it
export const examBreakText = (minutes) => minutes >= 15
  ? 'Leave your desk and walk, outside if you can. Phone stays in your pocket.'
  : 'Stand up, stretch, drink some water. Leave your phone alone.';

// "25, 8, 45, 10, 45" → focus, break, focus, break, focus. Starts and ends with a tomato; whole minutes, 1 to 480.
export function parseExamPlan(text) {
  const parts = String(text).split(/[^0-9]+/).filter(Boolean), plan = parts.map(Number);
  return plan.length >= 3 && plan.length <= 23 && plan.length % 2 === 1 && plan.every((m) => m >= 1 && m <= 480) ? plan : null;
}
export const examTomatoes = (plan) => plan.filter((_, i) => i % 2 === 0);
export const examText = (plan) => examTomatoes(plan).join(' → ') + ' min';  // "25 → 60 → 45 → 45 min"

// A tomato's name from its length: one of the four, or "50-min".
export const tomatoName = (minutes) => tiers.find((t) => t.minutes === minutes)?.name ?? `${minutes}-min`;

// The break after this round: 10 minutes, or what the Exam mode plan says. null: its last tomato (no next round).
export function breakAfter(s) {
  if (!s.plan.length) return groupBreakMinutes;
  const i = 2 * s.round - 1;
  return i + 1 < s.plan.length ? s.plan[i] : null;
}
export function nextRoundStart(s) {
  const b = breakAfter(s);
  return b == null ? null : s.startAt + (s.minutes + b) * 60000;
}

// The tomato someone picked for round `round` (a pick names its round, so one made a moment early or late
// can't be taken for another round's).
export const picked = (s, round) => (!s.plan.length && s.nextMinutes != null && s.nextRound === round
  ? { name: s.nextTierName ?? tomatoName(s.nextMinutes), minutes: s.nextMinutes } : null);

// The next round's tomato: the plan's, or what someone picked during the group break, or the same again.
export function nextTomato(s) {
  if (s.plan.length) {
    const minutes = 2 * s.round < s.plan.length ? s.plan[2 * s.round] : s.minutes;
    return { name: tomatoName(minutes), minutes };
  }
  return picked(s, s.round + 1) ?? { name: s.tierName, minutes: s.minutes };
}

// Tomatime 1.2.2 and older move the group on with the same tomato again: they don't know the pick or the plan.
// What this round should be instead (null: it's right); a newer Tomatime puts it right as the countdown shows.
export function roundFix(s) {
  if (s.round <= 1) return null;
  if (!s.plan.length) return picked(s, s.round);
  const m = s.plan[2 * (s.round - 1)];
  return m != null && m !== s.minutes ? { name: tomatoName(m), minutes: m } : null;
}

// A running group tomato can be made longer or shorter by anyone in it, as long as a minute of it is left.
// Not in its last 10 seconds: the others' may already have run out before the change reaches them.
export function canResize(s, minutes, now) {
  const phase = sessionPhase(s, now);
  return !s.plan.length && phase.kind === 'running' && phase.left > 10 && s.startAt + minutes * 60000 > now + 60000;
}

// A new group tomato never replaces one that's on, or a group break people picked (they'd lose their next round).
export function canStartSession(s, now) {
  if (!s || s.cancelled) return true;
  if (sessionPhase(s, now).kind !== 'over') return false;
  const next = nextRoundStart(s);
  return next == null || s.nextJoined.length === 0 || next <= now;
}

// The group's session line in the menu; minutes are rounded up. `here`: this PC is in this round.
// kind: start | starting | joinCountdown | inIt | otherDevice | joinRunning | onBreak | joinBreak (the last five carry m)
export function sessionMenu(s, me, device, here, now) {
  if (!s) return { kind: 'start' };
  const phase = sessionPhase(s, now);
  if (phase.kind === 'countdown') return { kind: here || otherDeviceHasIt(s, me, device) ? 'starting' : 'joinCountdown' };
  if (phase.kind === 'running') {
    const m = Math.ceil(phase.left / 60);
    return { kind: here ? 'inIt' : otherDeviceHasIt(s, me, device) ? 'otherDevice' : 'joinRunning', m };
  }
  const next = nextRoundStart(s);
  if (s.cancelled || s.nextJoined.length === 0 || next == null) return { kind: 'start' };
  const toNext = (next - now) / 1000;
  if (toNext <= 0) return { kind: 'start' };
  if (toNext <= countdownSeconds) return { kind: 'starting' };
  return { kind: s.nextJoined.includes(me) ? 'onBreak' : 'joinBreak', m: Math.ceil(toNext / 60) };
}

// This PC's minutes that count in a group: only from the day you joined.
export function secondsSince(local, joined) {
  const first = startOfDay(joined);
  return Object.fromEntries(Object.entries(local).filter(([key]) => {
    const p = key.split('-').map(Number);
    return p.length === 3 && p.every(Number.isInteger) && new Date(p[0], p[1] - 1, p[2]).getTime() >= first;
  }));
}

export const shouldAutoJoin = (idleSeconds) => idleSeconds < activeSeconds;

// I'm in this group tomato, but on another of my devices: this one shows nothing (or closes its countdown).
export const otherDeviceHasIt = (s, me, device) => s.joined.includes(me) && s.devices[me] !== device;

// What this PC shows when a group tomato's countdown begins: 'invite' | 'autoJoin' | 'starter' | null (nothing).
export function countdownMode(s, me, device, autoJoin, idleSeconds) {
  if (otherDeviceHasIt(s, me, device)) return null;
  if (s.joined.includes(me)) return s.startedBy === me && s.round === 1 ? 'starter' : 'autoJoin';
  return autoJoin && shouldAutoJoin(idleSeconds) ? 'autoJoin' : 'invite';
}

const codeAlphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';  // no 0/O, 1/I: easy to type

export function makeInviteCode(random = () => crypto.getRandomValues(new Uint32Array(1))[0] / 2 ** 32) {
  return 'TOMA-' + [...Array(6)].map(() => codeAlphabet[Math.floor(random() * codeAlphabet.length)]).join('');
}

// Typed codes: any case, spaces, dashes of any kind, quotes or a period around it; "TOMA" optional.
export function normalizeCode(s) {
  let c = s.toUpperCase().replace(/[^A-Z0-9]/g, '');
  if (c.length === 10 && c.startsWith('TOMA')) c = c.slice(4);  // no O in codes, so TOMA can't be part of one
  return c.length === 6 && [...c].every((ch) => codeAlphabet.includes(ch)) ? 'TOMA-' + c : null;
}

// Firestore boundary. `plain` turns Timestamps into milliseconds first.

export function plain(v) {
  if (v && typeof v.toMillis === 'function') return v.toMillis();
  if (Array.isArray(v)) return v.map(plain);
  if (v && typeof v === 'object') return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, plain(x)]));
  return v;
}

export const idleStatus = { state: 'idle', tierName: '', minutes: 0, endsAt: null, sessionID: null };

export const statusData = (s) => ({ state: s.state, tierName: s.tierName, minutes: s.minutes,
  endsAt: s.endsAt == null ? null : new Date(s.endsAt), sessionID: s.sessionID ?? null });

export const sameStatus = (a, b) => !!a && a.state === b.state && a.tierName === b.tierName && a.minutes === b.minutes
  && a.endsAt === b.endsAt && a.sessionID === b.sessionID;

const num = (v, fallback = 0) => (typeof v === 'number' ? v : fallback);

export function member(uid, data) {
  if (typeof data.name !== 'string' || typeof data.joinedAt !== 'number') return null;
  const st = data.status ?? {};
  const secs = Object.fromEntries(Object.entries(data.secondsByDevice ?? {}).map(([device, days]) =>
    [device, Object.fromEntries(Object.entries(days ?? {}).filter(([, v]) => typeof v === 'number'))]));
  return { uid, name: data.name, joinedAt: data.joinedAt, hasPass: data.hasPass === true,
    status: { state: ['focus', 'break', 'idle'].includes(st.state) ? st.state : 'idle',
      tierName: typeof st.tierName === 'string' ? st.tierName : '', minutes: num(st.minutes),
      endsAt: typeof st.endsAt === 'number' ? st.endsAt : null, sessionID: typeof st.sessionID === 'string' ? st.sessionID : null },
    secondsByDevice: secs };
}

// Round 1 stores only the server's createdAt (start = 10 s later); later rounds store startAt.
// `id` changes every round; the document itself is always groups/{gid}/sessions/current.
export function session(data) {
  const startAt = typeof data.startAt === 'number' ? data.startAt
    : typeof data.createdAt === 'number' ? data.createdAt + countdownSeconds * 1000 : null;
  if (typeof data.id !== 'string' || typeof data.startedBy !== 'string' || startAt == null) return null;
  return { id: data.id, round: num(data.round, 1), startedBy: data.startedBy, starterName: data.starterName ?? '',
    tierName: data.tierName ?? '', minutes: num(data.minutes), startAt, cancelled: data.cancelled === true,
    joined: data.joined ?? [], nextJoined: data.nextJoined ?? [], devices: data.devices ?? {},
    plan: Array.isArray(data.plan) ? data.plan.map(Number) : [],
    nextTierName: typeof data.nextTierName === 'string' ? data.nextTierName : null,
    nextMinutes: typeof data.nextMinutes === 'number' ? data.nextMinutes : null,
    nextRound: typeof data.nextRound === 'number' ? data.nextRound : null };
}

export class GroupError extends Error {
  static text = {
    offline: "Couldn't reach Tomatime Groups. Check your connection.",
    notSignedIn: 'Sign in first.',
    noSuchCode: 'No group has that invite code. Check it and try again.',
    full: 'This group is full (6 people).',
    notAllowed: "You can't do that in this group.",
    busy: 'A group tomato or group break is already on in this group. Join it from the menu.',
  };
  constructor(code) { super(GroupError.text[code]); this.code = code; }
}

// Firestore waits forever while offline; user actions give up after 10 s instead.
export function withTimeout(work, seconds = 10) {
  let timer;
  return Promise.race([
    work(),
    new Promise((_, reject) => { timer = setTimeout(() => reject(new GroupError('offline')), seconds * 1000); }),
  ]).finally(() => clearTimeout(timer));
}

// The shared timer (users/{uid}/timer/current): the one tomato a person's Mac, iPhone, Watch and PC all follow.
// { phase: 'focus' | 'break' | 'idle', tier, minutes, running, endAt (unix s, while running), left (s, paused), by, at }

export const idleTimer = (by, now) =>
  ({ phase: 'idle', tier: '', minutes: 0, running: false, endAt: null, left: 0, by, at: now / 1000 });

export function timerFrom(data) {
  if (!data || !['focus', 'break', 'idle'].includes(data.phase)) return null;
  return { phase: data.phase, tier: data.tier ?? '', minutes: num(data.minutes), running: data.running === true,
    endAt: typeof data.endAt === 'number' ? data.endAt : null, left: num(data.left), by: data.by ?? '', at: num(data.at) };
}

// Same timer, ignoring who changed it and when (and sub-second clock noise).
export function sameTimer(a, b) {
  if (!a) return false;
  if (a.phase === 'idle' && b.phase === 'idle') return true;
  return a.phase === b.phase && a.tier === b.tier && a.minutes === b.minutes && a.running === b.running
    && Math.abs((a.endAt ?? 0) - (b.endAt ?? 0)) < 1 && (a.running || Math.abs(a.left - b.left) < 1);
}

// "24:12", or "2:04:12" past an hour.
export function clock(seconds) {
  const s = Math.max(0, Math.ceil(seconds)), two = (n) => String(n).padStart(2, '0');
  return s > 3600 ? `${Math.floor(s / 3600)}:${two(Math.floor(s / 60) % 60)}:${two(s % 60)}` : `${Math.floor(s / 60)}:${two(s % 60)}`;
}
