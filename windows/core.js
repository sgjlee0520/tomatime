// The timer and the group tomato on this PC, ported from main.swift (App), Groups/GroupsUI.swift and
// Groups/TimerSync.swift. It decides; main.js draws (tray, countdown, red screen). No Electron here, so
// core.test.js can run it in plain Node.
import { tiers, tierColor, maxFocusMinutes, countdownSeconds, groupBreakMinutes, dayKey, wholeMinutes, sessionPhase,
  sessionEnd, nextRoundStart, otherDeviceHasIt, countdownMode, idleTimer, sameTimer, sameStatus, breakAfter, nextTomato,
  roundFix, canResize, tomatoName, examTomatoes, examText, examBreakText, examDoneText, recommendedExamPlan } from './rules.js';

// A tomato of any length: a typed one takes the color of the biggest of the four it reaches.
const tomatoTier = (name, minutes) => ({ name, minutes, color: tierColor(name, minutes) });
export const tomatoText = (name, minutes) =>
  (name.endsWith('-min') ? `${Math.floor(minutes)} min tomato` : `${name} tomato · ${Math.floor(minutes)} min`);

const after = (at, f) => setTimeout(f, Math.max(0, at - Date.now()));

export class Core {
  onBreak = false;
  autoNext = false;     // start the next focus session when this break ends
  focused = 0;          // minutes in this focus session, "1 more minute"s included
  left = 0;             // seconds remaining while paused
  end = null;           // ms, set while running; wall-clock, so sleep doesn't drift it
  breakMinutes = 0;     // length of the current break
  custom = null;        // typed-in length; picking a tier clears it
  exam = null;          // solo Exam mode: { plan, block } (a group's is its session's plan)
  shared = null;        // the shared timer as last written or seen
  group = { gid: null, sid: null, tier: null, showing: null, joining: null, seen: new Set(), lastStatus: null };
  #ticker; #lastCount = Date.now(); #applyingRemote = false; #startTimer; #advanceTimer;

  // settings: get(key, fallback) / set(key, value), kept between launches. ui: render(), showDone(info),
  // closeDone(), showCountdown(info), countdownNames(joined, waiting), closeCountdown(), sound(name).
  // unit: seconds per "minute" (1 with --fast). idleSeconds(): how long since the PC was last used.
  constructor({ store, settings, ui, deviceKey, unit = 60, emulator = false, idleSeconds = () => 0 }) {
    Object.assign(this, { store, settings, ui, deviceKey, unit, emulator, idleSeconds });
    this.tierIndex = Math.min(settings.get('tier', 1), tiers.length - 1);
    this.statsKey = unit === 60 && !emulator ? 'focusSeconds' : 'focusSecondsFast';
    store.onChange = () => this.groupsChanged();
    store.onTimer = (s) => this.applyRemote(s);
    this.reset();
  }

  get tier() {
    const e = this.exam, m = e && e.plan[2 * e.block];
    return this.group.tier ?? (e ? tomatoTier(tomatoName(m), m) : null) ?? this.custom ?? tiers[this.tierIndex];
  }
  get examPlan() {
    const plan = this.settings.get('examPlan', null);
    return Array.isArray(plan) && plan.length >= 3 ? plan : recommendedExamPlan;
  }
  get secondsLeft() { return this.end != null ? Math.max(0, (this.end - Date.now()) / 1000) : this.left; }
  tally() { return this.settings.get(this.statsKey, {}); }
  todayText() {
    const m = wholeMinutes(this.tally()[dayKey()] ?? 0);
    return `${m} tomato minute${m === 1 ? '' : 's'} today`;
  }

  // Adds focus time since the last count to today's tally. A gap over 5 s means the PC slept: not counted.
  countFocus() {
    if (this.onBreak || this.end == null) return;
    const now = Date.now(), gap = (Math.min(now, this.end) - this.#lastCount) / 1000;
    this.#lastCount = now;
    if (gap <= 0 || gap >= 5) return;
    const days = { ...this.tally() };
    days[dayKey()] = (days[dayKey()] ?? 0) + gap * 60 / this.unit;
    this.settings.set(this.statsKey, days);
  }

  run(seconds) {
    this.left = seconds;
    this.end = Date.now() + seconds * 1000;
    this.#lastCount = Date.now();
    clearInterval(this.#ticker);
    this.#ticker = setInterval(() => this.tick(), 1000);
    this.render();
    this.publishTimer();
  }

  stop() {
    clearInterval(this.#ticker);
    this.end = null;
    this.publishMinutes();  // on pause, finish and reset; not every second
  }

  toggle() {
    this.leaveGroupTomato();  // Pause takes only you out of a group tomato
    if (this.end == null) return this.run(this.left);
    this.countFocus();
    this.left = this.secondsLeft;
    this.stop();
    this.render();
    this.publishTimer();
  }

  tick() {
    this.countFocus();
    if (this.end == null || this.end > Date.now()) return this.render();
    this.stop();
    this.left = 0;
    if (this.onBreak) {
      this.ui.sound('breakEnd');
      const next = this.autoNext;
      if (this.exam) this.exam.block += 1;  // Exam mode: on to its next tomato
      // A break my other Mac or PC started ends there too, and that one says what's next: an "idle" from here
      // could land after its next tomato and stop it.
      this.#applyingRemote = !!this.shared && this.shared.by !== this.deviceKey && this.shared.by.startsWith('focus-');
      this.reset();
      this.#applyingRemote = false;
      if (next) this.run(this.left);
    } else {
      this.ui.sound('focusEnd');
      this.render();
      if (!this.examBlockEnded()) this.showDone();
    }
  }

  // The red screen. `exam`: Exam mode's instead (its break has already started, or it's all done).
  showDone(exam = null) {
    const s = this.group.gid && this.store.sessions[this.group.gid];
    this.ui.showDone({ tierName: this.tier.name, color: this.tier.color, focused: Math.floor(this.focused),
      today: this.todayText(), inGroup: this.group.gid != null, canExtend: this.focused + 1 <= maxFocusMinutes,
      groupBreak: (s && breakAfter(s)) ?? groupBreakMinutes, exam });
  }

  // MARK: Exam mode

  // Start: the plan's tomatoes and breaks, back to back. While it runs: Stop.
  examTapped() {
    if (this.exam) return this.resetTapped();
    this.leaveGroupTomato();
    this.exam = { plan: this.examPlan, block: 0 };
    this.reset();
    this.run(this.left);
  }

  // A tomato of an Exam mode just ended: its break starts by itself (solo) or with the group, and after the
  // last one it's done. False: not in Exam mode (the usual red screen).
  examBlockEnded() {
    const breakScreen = (k, n, b, next) => ({ title: `Tomato ${k} of ${n} done!`,
      sub: `${b} min break, then a ${next} min tomato.\n${examBreakText(b)}`, ok: 'OK', leave: 'Leave Exam mode' });
    const doneScreen = { title: 'Exam mode done!', sub: `${this.todayText()}. ${examDoneText}`, ok: 'Done', done: true };
    const { gid, sid } = this.group, s = gid && this.store.sessions[gid];
    if (s && s.id === sid && s.plan.length) {
      const b = breakAfter(s);
      if (b == null) { this.showDone(doneScreen); return true; }
      if (!this.joinNextRound(gid, s)) return false;
      this.showDone(breakScreen(s.round, examTomatoes(s.plan).length, b, nextTomato(s).minutes));
      return true;
    }
    const e = this.exam;
    if (!e) return false;
    if (2 * e.block + 2 >= e.plan.length) {
      this.exam = null;
      this.showDone(doneScreen);
      return true;
    }
    this.onBreak = true;
    this.autoNext = true;
    this.breakMinutes = e.plan[2 * e.block + 1];
    this.run(this.breakMinutes * this.unit);
    this.showDone(breakScreen(e.block + 1, examTomatoes(e.plan).length, this.breakMinutes, e.plan[2 * e.block + 2]));
    return true;
  }

  reset() {
    this.countFocus();
    this.stop();
    this.ui.closeDone();
    this.onBreak = false;
    this.autoNext = false;
    this.group.tier = null;
    this.focused = this.tier.minutes;
    this.left = this.tier.minutes * this.unit;
    this.render();
    this.publishTimer(true);
  }

  pickTier(i) {
    this.leaveGroupTomato();
    this.exam = null;
    this.tierIndex = i;
    this.settings.set('tier', i);
    this.custom = null;
    this.reset();
  }

  // A typed length (whole minutes, 1 to 480), started right away. It repeats after "break, then next session".
  customTomato(m) {
    this.leaveGroupTomato();
    this.exam = null;
    this.custom = tomatoTier(`${m}-min`, m);
    this.reset();
    this.run(this.left);
  }

  startBreak(minutes, thenNext = false) {
    this.leaveGroupTomato();  // the solo buttons on the red screen
    this.exam = null;
    this.ui.closeDone();
    this.onBreak = true;
    this.autoNext = thenNext;
    this.breakMinutes = minutes;
    this.run(minutes * this.unit);
  }

  oneMore() {
    this.leaveGroupTomato();
    this.exam = null;
    this.ui.closeDone();
    this.focused += 1;
    this.run(this.unit);
  }

  resetTapped() {
    this.leaveGroupTomato();
    this.exam = null;
    this.reset();
  }

  render() {
    this.ui.render();
    this.publishStatus();
  }

  // Quitting: what the Mac does in applicationWillTerminate.
  quit() {
    this.countFocus();
    this.publishMinutes();
  }

  // MARK: The shared timer (TimerSync.swift): this PC follows the person's iPhone, Watch and Mac, and they follow it.

  // After every local change. Only for an Apple sign-in (a code sign-in has no other devices), real minutes only.
  publishTimer(idle = false) {
    const { store } = this;
    if (this.#applyingRemote || !store.signedIn || store.anonymous || !(this.unit === 60 || this.emulator)) return;
    const now = Date.now();
    const s = idle ? idleTimer(this.deviceKey, now) : {
      phase: this.onBreak ? 'break' : 'focus', tier: this.onBreak ? 'Break' : this.tier.name,
      minutes: this.onBreak ? this.breakMinutes : this.focused, running: this.end != null,
      endAt: this.end != null ? this.end / 1000 : null, left: this.left, by: this.deviceKey, at: now / 1000 };
    if (sameTimer(this.shared, s)) return;
    this.shared = s;
    store.writeTimer(s);
  }

  // A change from my phone, watch or Mac.
  applyRemote(s) {
    if (s.by === this.deviceKey || sameTimer(this.shared, s)) return;
    this.shared = s;
    const now = Date.now() / 1000;
    if (s.running && (s.endAt ?? 0) <= now) return;  // already over (e.g. seen at launch)
    this.#applyingRemote = true;
    try {
      // Pausing or resuming Exam mode's tomato or break from the phone or watch keeps it going; anything else ends it.
      const sameBlock = !!this.exam && s.phase === (this.onBreak ? 'break' : 'focus')
        && s.minutes === (this.onBreak ? this.breakMinutes : this.focused);
      if (!sameBlock) this.exam = null;
      this.leaveGroupTomato();
      this.ui.closeDone();
      if (s.phase === 'idle') return this.reset();
      this.onBreak = s.phase === 'break';
      this.autoNext = sameBlock && this.onBreak;
      if (this.onBreak) {
        this.breakMinutes = s.minutes;
      } else {
        const i = tiers.findIndex((t) => t.name === s.tier && t.minutes === s.minutes);
        if (sameBlock) { /* Exam mode's tomato: my own pick stays what it was */ } else if (i >= 0) { this.tierIndex = i; this.custom = null; } else {
          this.custom = tomatoTier(s.tier, s.minutes);
        }
        this.focused = s.minutes;
      }
      if (s.running && s.endAt != null) {
        this.run(s.endAt - now);
      } else {
        this.countFocus();
        this.stop();
        this.left = s.left;
        this.render();
      }
    } finally { this.#applyingRemote = false; }
  }

  // MARK: Group tomatoes (GroupsUI.swift)

  groupsChanged() {
    const { store, group } = this, me = store.uid;
    this.render();
    if (!me) return;
    for (const g of store.groups) {
      const s = store.sessions[g.id];
      if (!s) continue;
      const phase = sessionPhase(s, Date.now()), fix = phase.kind !== 'over' && roundFix(s);
      if (fix) store.setTomato(g.id, s.id, fix.name, fix.minutes, false);  // an older Tomatime moved the group on with the old tomato
      // Someone in it changed its length. (No `end`: mine had just run out, the red screen is up; on it goes.)
      if (group.gid === g.id && group.sid === s.id && !this.onBreak && phase.kind === 'running'
          && (this.end != null ? Math.abs(this.end - sessionEnd(s)) > 1000 : phase.left > 2)) {
        this.countFocus();
        this.ui.closeDone();
        this.focused = Math.max(1, this.focused + Math.round((sessionEnd(s) - (this.end ?? Date.now())) / 60000));
        group.tier = tomatoTier(s.tierName, s.minutes);
        this.ui.sound('change');
        this.run(phase.left);
      }
      if (group.showing?.gid === g.id) {
        if (group.showing.sid !== s.id || s.cancelled || otherDeviceHasIt(s, me, this.deviceKey)) this.closeCountdown();
        else this.ui.countdownNames(...this.joinedNames(g, s));
      }
      if (phase.kind !== 'countdown' || group.seen.has(s.id) || this.#countdownUp()) continue;
      group.seen.add(s.id);
      const mode = countdownMode(s, me, this.deviceKey, this.autoJoins(g.id), this.idleSeconds());
      if (mode) this.showCountdown(g, s, mode);
    }
  }

  #countdownUp() {
    const shown = this.group.showing, s = shown && this.store.sessions[shown.gid];
    return !!s && s.id === shown.sid && s.startAt > Date.now();
  }

  showCountdown(g, s, mode) {
    const me = this.store.uid;
    const who = s.startedBy === me ? 'You' : s.starterName;
    const what = tomatoText(s.tierName, s.minutes), n = examTomatoes(s.plan).length;
    const title = !s.plan.length || s.round > n ? (s.round === 1 ? `${who} started a 🍅 ${what}` : `next group 🍅 ${what}`)
      : s.round === 1 ? `${who} started Exam mode · ${examText(s.plan)}` : `Exam mode ${s.round} of ${n} · 🍅 ${what}`;
    this.ui.closeCountdown();
    this.group.showing = { gid: g.id, sid: s.id };
    const [joined, waiting] = this.joinedNames(g, s);
    this.ui.showCountdown({ gid: g.id, sid: s.id, mode, startAt: s.startAt, joined, waiting,
      title: `${g.name}: ${title}`,
      note: s.round > 1 && s.joined.includes(me) ? 'You picked the group break' : 'Auto-join is on' });
    if (mode !== 'invite') this.joinRound(g.id, s.id);
    this.scheduleStart(g.id, s.id, s.startAt);
  }

  closeCountdown() {
    this.ui.closeCountdown();
    this.group.showing = null;
    this.group.joining = null;
  }

  joinedNames(g, s) {
    const name = (m) => (m.uid === this.store.uid ? 'You' : m.name);
    return [g.members.filter((m) => s.joined.includes(m.uid)).map(name), g.members.filter((m) => !s.joined.includes(m.uid)).map(name)];
  }

  // This PC will start the round at 0 (and claims it, so my other devices stand down).
  joinRound(gid, sid) {
    this.group.joining = sid;
    const me = this.store.uid, s = this.store.sessions[gid];
    if (!me || s?.id !== sid) return;
    if (!s.joined.includes(me) || s.devices[me] !== this.deviceKey) this.store.setJoined(gid, sid, true);
  }

  skipRound(gid, sid) {
    const { group, store } = this;
    if (group.showing?.sid === sid) group.showing = null;
    if (group.joining === sid) group.joining = null;
    if (group.gid === gid) { group.gid = null; group.sid = null; }  // skipping the next round ends the group rhythm
    const me = store.uid, s = store.sessions[gid];
    if (me && s?.id === sid && s.joined.includes(me) && s.devices[me] === this.deviceKey) store.setJoined(gid, sid, false);
  }

  // The starter's Cancel on the countdown.
  cancelRound(gid, sid) {
    this.store.cancelSession(gid, sid);
    this.skipRound(gid, sid);
  }

  scheduleStart(gid, sid, at) {
    clearTimeout(this.#startTimer);
    this.#startTimer = after(at, () => this.roundStarts(gid, sid));
  }

  roundStarts(gid, sid) {
    const s = this.store.sessions[gid], me = this.store.uid;
    if (s?.id !== sid || s.cancelled) return;
    if (s.startAt - Date.now() > 50) return this.scheduleStart(gid, sid, s.startAt);  // server time came in later
    if (this.group.joining !== sid || !me) return;
    this.group.joining = null;
    // This PC chose to be in; its join may still be on the way to the server. Only my other device's claim stops it.
    if (!otherDeviceHasIt(s, me, this.deviceKey)) this.startGroupTomato(gid, s);
  }

  // Everyone in it ends at the same second; joining late gets the time left. A solo tomato's minutes so far still count.
  startGroupTomato(gid, s) {
    const secs = (sessionEnd(s) - Date.now()) / 1000;
    if (secs <= 1) return;
    this.countFocus();
    this.ui.closeDone();
    Object.assign(this.group, { gid, sid: s.id, tier: tomatoTier(s.tierName, s.minutes) });
    this.exam = null;
    clearTimeout(this.#advanceTimer);
    this.onBreak = false;
    this.autoNext = false;
    this.focused = Math.max(1, Math.round(secs / 60));
    this.run(secs);
  }

  // Red screen after a group tomato: 10-minute break that ends as the next group tomato starts.
  // `pick`: one of the four small buttons under it (which tomato): the same, and the next one is that tomato.
  groupBreak(pick = null) {
    const { gid, sid } = this.group, s = gid && this.store.sessions[gid];
    if (!(s && s.id === sid && this.joinNextRound(gid, s))) return this.startBreak(groupBreakMinutes);  // missed it
    if (tiers[pick]) this.store.setTomato(gid, s.id, tiers[pick].name, tiers[pick].minutes, true);
  }

  // Exam mode for the group: this PC's plan, tomatoes and breaks back to back for everyone who joins.
  startGroupExam(gid) {
    const plan = this.examPlan;
    return this.store.startSession(gid, tomatoName(plan[0]), plan[0], plan);
  }

  // While the group tomato runs: its length, for everyone in it. On the group break: the next round's tomato.
  // False: that tomato would already be over.
  changeGroupTomato(gid, name, minutes) {
    const s = this.store.sessions[gid], phase = s && sessionPhase(s, Date.now()).kind;
    if (phase === 'running') {
      if (!canResize(s, minutes, Date.now())) return false;
      this.store.setTomato(gid, s.id, name, minutes, false);
    } else if (phase === 'over') this.store.setTomato(gid, s.id, name, minutes, true);
    return true;
  }

  // Opt in to the round after `s`: a break that ends as it starts. False when it's under 10 s away.
  // From the red screen, or from the menu while the others are on their group break.
  joinNextRound(gid, s) {
    const start = nextRoundStart(s);
    if (start == null || start - Date.now() <= countdownSeconds * 1000) return false;
    this.store.setNextJoined(gid, s.id, true);
    this.countFocus();
    this.group.gid = gid;
    this.group.sid = s.id;
    this.ui.closeDone();
    this.onBreak = true;
    this.autoNext = false;
    this.exam = null;
    this.breakMinutes = breakAfter(s) ?? groupBreakMinutes;
    this.run((start - Date.now()) / 1000);
    clearTimeout(this.#advanceTimer);  // whoever is first moves everyone opted in to the next round
    this.#advanceTimer = after(start - countdownSeconds * 1000, () => this.store.advanceRound(gid, s.round, start));
    return true;
  }

  // Pause, Reset, a tier, Custom, or a solo button on the red screen: only I leave; the others keep going.
  leaveGroupTomato() {
    const { group, store } = this, gid = group.gid;
    if (!gid) return;
    group.gid = null;
    group.sid = null;
    clearTimeout(this.#advanceTimer);
    if (group.showing?.gid === gid) this.closeCountdown();
    const me = store.uid, s = store.sessions[gid];
    if (!me || !s || s.devices[me] !== this.deviceKey) return;
    if (s.joined.includes(me) && sessionPhase(s, Date.now()).kind !== 'over') store.setJoined(gid, s.id, false);
    if (s.nextJoined.includes(me)) store.setNextJoined(gid, s.id, false);
  }

  // Arrived late, or skipped the countdown and changed your mind (the Join line in the menu).
  joinGroupTapped(gid) {
    const s = this.store.sessions[gid];
    if (!s) return;
    if (this.group.gid !== gid) this.leaveGroupTomato();
    const phase = sessionPhase(s, Date.now()).kind;
    if (phase === 'countdown') { this.joinRound(gid, s.id); this.scheduleStart(gid, s.id, s.startAt); }
    else if (phase === 'running') { this.store.setJoined(gid, s.id, true); this.startGroupTomato(gid, s); }
    else this.joinNextRound(gid, s);  // the others are on their group break
  }

  // This PC's own minutes, under its own device id.
  publishMinutes() {
    if (this.store.signedIn) this.store.publishSeconds(this.deviceKey.slice('focus-'.length), this.tally());
  }

  // Only on change, and only while signed in: writes stay at one per start, pause, break or stop.
  publishStatus() {
    if (!this.store.signedIn) return;
    const focusing = this.end != null && !this.onBreak;
    const st = { state: this.end == null ? 'idle' : this.onBreak ? 'break' : 'focus', tierName: focusing ? this.tier.name : '',
      minutes: focusing ? this.tier.minutes : 0, endsAt: this.end, sessionID: focusing ? this.group.sid : null };
    if (sameStatus(this.group.lastStatus, st)) return;
    this.group.lastStatus = st;
    this.store.publish(st);
  }

  autoJoins(gid) { return this.settings.get(`autoJoin.${gid}`, false); }
}
