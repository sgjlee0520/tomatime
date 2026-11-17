// Tomatime for Windows: the tray icon, its menu, and the windows (welcome, small questions, the group countdown,
// the red end screen). The timer and the group tomato: core.js. Firebase: store.js. Rules: rules.js.
// Run: npm start [-- --emulator --fast]   (--emulator: the local Firebase emulators; --fast: a "minute" is a second)
// --shots=<folder>: draw the icon, the menu and every window into files with sample people, show nothing, quit.
// --emulator --fast --selftest: click through the real windows (kept hidden) against the emulators, then quit 0 or 1.
//   With --visible --snap=<folder> (the Windows test machine): windows are shown and the screen is photographed.
import { app, BrowserWindow, Tray, Menu, nativeImage, ipcMain, dialog, clipboard, shell, screen, powerMonitor,
  safeStorage, desktopCapturer } from 'electron';
import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { GroupStore } from './store.js';
import { Core, tomatoText } from './core.js';
import { tomatoBitmap, iconText } from './icon.js';
import { signInURL, waitForToken, newNonce } from './apple.js';
import { tiers, maxFocusMinutes, maxGroupSize, GroupError, normalizeCode, clock, effectiveState, statusText,
  friendsFocusing, sessionMenu, weeklyRanking, nextTomato, examTomatoes, examText, parseExamPlan, recommendedExamPlan } from './rules.js';

const here = import.meta.dirname, flag = (name) => process.argv.includes(name);
const emulator = flag('--emulator'), fast = flag('--fast');
const shots = process.argv.find((a) => a.startsWith('--shots='))?.slice(8), selftest = flag('--selftest');
const snaps = process.argv.find((a) => a.startsWith('--snap='))?.slice(7);
const hidden = !!shots || (selftest && !flag('--visible'));  // windows are made and drawn, never shown
const preload = path.join(here, 'preload.cjs'), page = (file) => path.join(here, 'ui', file);
const appIcon = nativeImage.createFromPath(path.join(here, 'assets', 'icon.png'));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// The real app keeps its files in %APPDATA%\Tomatime; a development or emulator run never touches them.
if (!app.isPackaged || emulator || shots) {
  app.setPath('userData', path.join(app.getPath('appData'), `Tomatime PC ${shots ? 'shots' : selftest ? 'selftest' : emulator ? 'emulator' : 'dev'}`));
  if (selftest) fs.rmSync(app.getPath('userData'), { recursive: true, force: true });  // every run starts like a new person
}
if (!app.requestSingleInstanceLock()) app.exit();
app.setAppUserModelId('com.sgjlee.tomatime');
app.dock?.hide();                         // on a Mac (development) it's a menu-bar app, like the real Mac app
app.on('window-all-closed', () => {});    // it lives in the tray

let core, store, settings, config, tray, lastIcon = '';

// A small JSON file in the app's folder. secret: encrypted for this Windows account (the saved sign-in).
function jsonFile(name, { secret = false, delay = 3000 } = {}) {
  const file = path.join(app.getPath('userData'), name);
  const lock = secret && process.platform === 'win32' && safeStorage.isEncryptionAvailable();
  let data = {}, timer = null;
  try { const raw = fs.readFileSync(file); data = JSON.parse(lock ? safeStorage.decryptString(raw) : raw.toString()); } catch { /* first run */ }
  const write = () => {
    clearTimeout(timer); timer = null;
    const text = JSON.stringify(data);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, lock ? safeStorage.encryptString(text) : text);
  };
  return { get: (k, fallback) => (k in data ? data[k] : fallback), flush: () => { if (timer) write(); },
    set(k, v) { if (v === undefined) delete data[k]; else data[k] = v; if (!delay) write(); else timer ??= setTimeout(write, delay); } };
}

// MARK: What the timer asks the screen to do (core.js `ui`)

const ui = {
  render() {
    if (!core || !tray) return;
    const key = iconKey().join('|');
    if (key !== lastIcon) { lastIcon = key; tray.setImage(trayImage(...iconKey())); }
    tray.setToolTip(tip());
  },
  sound: () => shell.beep(),  // ponytail: the system sound for both endings; own sounds if people ask
  showDone(info) { ui.closeDone(); doneWins = overlays('done.html', info); },
  closeDone() { closeAll(doneWins); doneWins = []; },
  showCountdown(info) { closeAll(countdownWins); showing = info; countdownWins = overlays('countdown.html', info); },
  countdownNames: (joined, waiting) => tellAll(countdownWins, 'names', { joined, waiting }),
  closeCountdown() { closeAll(countdownWins); countdownWins = []; showing = null; },
};
let doneWins = [], countdownWins = [], showing = null;
const closeAll = (wins) => wins.forEach((w) => !w.isDestroyed() && w.destroy());
const tellAll = (wins, what, data) => wins.forEach((w) => !w.isDestroyed() && w.webContents.send('tomatime:' + what, data));

// MARK: Tray

const friends = () => (settings.get('hideFriendsCount', false) ? 0 : friendsFocusing(store.groups, store.uid ?? '', Date.now()));
const iconKey = () => [core.onBreak ? '#8c9eb3' : core.tier.color, core.end != null ? iconText(core.secondsLeft) : '', friends() > 0];

function trayImage(color, text, dot) {
  const img = nativeImage.createFromBitmap(tomatoBitmap(16, color, text, dot), { width: 16, height: 16, scaleFactor: 1 });
  img.addRepresentation({ scaleFactor: 2, width: 32, height: 32, buffer: tomatoBitmap(32, color, text, dot) });
  return img;
}

function tip() {
  const untouched = core.end == null && !core.onBreak && core.left >= core.tier.minutes * core.unit;
  const what = untouched ? `Tomatime · ${core.todayText()}`
    : `${core.onBreak ? 'Break' : `${core.tier.name} tomato`} · ${clock(core.secondsLeft)} left${core.end == null ? ' (paused)' : ''}`;
  const n = friends();
  return n > 0 ? `${what} · ${n} focusing` : what;
}

// MARK: Menu (the Mac app's menu, GroupsUI.swift: one line per group)

function menuTemplate() {
  const item = (label, click, more = {}) => ({ label, click, ...more }), line = { type: 'separator' };
  const groups = groupsOn() ? [line, ...store.groups.map(groupLine), groupsItem()] : [];
  return [
    { label: core.todayText(), enabled: false },
    ...groups,
    line,
    item(core.end == null ? 'Start' : 'Pause', () => core.toggle()),
    item('Reset', () => core.resetTapped()),
    line,
    ...tiers.map((t, i) => item(`${t.name} tomato · ${t.minutes} min`, () => core.pickTier(i),
      { type: 'radio', checked: !core.exam && !core.custom && i === core.tierIndex })),
    item(core.custom ? `Custom tomato · ${core.custom.minutes} min…` : 'Custom tomato…', customTomato,
      { type: 'radio', checked: !!core.custom && !core.exam }),
    { label: core.exam ? `Exam mode · tomato ${core.exam.block + 1} of ${examTomatoes(core.exam.plan).length}` : 'Exam mode', submenu: [
      item(core.exam ? 'Stop Exam mode' : `Start · ${examText(core.examPlan)}`, () => core.examTapped()),
      item('Change the Plan…', editExam)] },
    line,
    item('Open at login', () => app.setLoginItemSettings({ openAtLogin: !app.getLoginItemSettings().openAtLogin }),
      { type: 'checkbox', checked: app.getLoginItemSettings().openAtLogin, visible: app.isPackaged }),
    item('Quit', () => app.quit()),
  ];
}

function groupLine(g) {
  const now = Date.now(), me = store.uid, item = (label, click, more = {}) => ({ label, click, ...more }), line = { type: 'separator' };
  const info = (label) => ({ label, enabled: false });
  const busy = g.members.filter((m) => m.uid !== me && effectiveState(m.status, now) === 'focus').length, n = g.members.length;
  const icon = { focus: '🍅', break: '☕', idle: '💤' };
  const hm = (m) => (m < 60 ? `${m}m` : m % 60 === 0 ? `${m / 60}h` : `${Math.floor(m / 60)}h ${m % 60}m`);
  const ranking = weeklyRanking({ ...g, members: g.members.map((m) => (m.uid === me ? { ...m, name: 'You' } : m)) }, now, firstWeekday());
  const owner = g.ownerUID !== me ? [] : [line,
    item('New invite code…', () => newCode(g)),
    ...(n > 1 ? [{ label: 'Remove member', submenu: g.members.filter((m) => m.uid !== me).map((m) => item(`${m.name}…`, () => removeMember(g, m))) }] : []),
    item('Rename group…', () => renameGroup(g))];
  return { label: `👥 ${g.name} · ${busy > 0 ? `${busy} focusing` : `${n} member${n === 1 ? '' : 's'}`}`, submenu: [
    ...g.members.map((m) => info(`${icon[effectiveState(m.status, now)]} ${m.name}${m.uid === me ? ' (you)' : ''} · ${statusText(m, now)}`)),
    line,
    sessionItem(g, now),
    item('Auto-join', () => settings.set(`autoJoin.${g.id}`, !core.autoJoins(g.id)), { type: 'checkbox', checked: core.autoJoins(g.id) }),
    ...(store.code(g.id) ? [item(`Copy invite code (${store.code(g.id)})`, () => clipboard.writeText(store.code(g.id)))] : []),
    { label: 'This week', submenu: ranking.map((r, i) => info(`${['🥇', '🥈', '🥉'][i] ?? `${i + 1}.`}  ${r.name} · ${hm(r.minutes)}`)) },
    ...owner,
    line,
    item('Leave group…', () => leaveGroup(g)),
  ] };
}

function sessionItem(g, now) {
  const s = store.sessions[g.id], here = !!s && (core.group.joining === s.id || core.group.sid === s.id);
  const info = (label) => ({ label, enabled: false }), join = (label) => ({ label, click: () => core.joinGroupTapped(g.id) });
  const menu = sessionMenu(s, store.uid ?? '', core.deviceKey, here, now), m = menu.m;
  // A line with the four tomatoes and Custom tomato… under it (pick() with no tomato: Custom, which asks the minutes).
  const choices = (label, pick, header) => ({ label, submenu: [...(header ? [info(header)] : []),
    ...tiers.map((t) => ({ label: `${t.name} tomato · ${t.minutes} min`, click: () => pick(t.name, t.minutes) })),
    { label: 'Custom tomato…', click: () => pick() }] });
  const change = (name, minutes) => changeGroup(g, name, minutes);
  const k = s && s.round + (menu.kind === 'onBreak' ? 1 : 0), n = s ? examTomatoes(s.plan).length : 0;
  const exam = s?.plan.length ? (k <= n ? ` · Exam mode ${k} of ${n}` : ' ') : '';  // ' ': an Exam mode an older app carried on
  switch (menu.kind) {
    case 'start': {  // any tomato a solo session can be; or Exam mode
      const start = choices('Start group tomato', (name, minutes) => startGroup(g, name, minutes));
      start.submenu.push({ type: 'separator' },
        { label: `Exam mode · ${examText(core.examPlan)}`, click: () => groupTask(() => core.startGroupExam(g.id)) });
      return start;
    }
    case 'starting': return info('Group tomato starting…');
    case 'joinCountdown': return join('Group tomato starting — Join');
    case 'inIt':  // anyone in it can change its length (not an Exam mode's: the plan sets those)
      return exam ? info(`In this group tomato · ${m} min left${exam}`)
        : choices(`In this group tomato · ${m} min left`, change, 'Change its length, for everyone in it:');
    case 'otherDevice': return info(`In this group tomato on your other device · ${m} min left`);
    case 'joinRunning': return join(`Group tomato in progress — Join (${m} min left)`);
    case 'onBreak': {  // …or pick another tomato for the next round
      if (exam) return info(`Group break · next group tomato in ${m} min${exam}`);
      const next = nextTomato(s);
      return choices(`Group break · next: ${tomatoText(next.name, next.minutes)} in ${m} min`, change, 'Change the next group tomato:');
    }
    default: return join(`Group break · next group tomato in ${m} min — Join`);
  }
}

function groupsItem() {
  const item = (label, click, more = {}) => ({ label, click, ...more });
  return { label: 'Groups', submenu: [
    ...(!store.signedIn && config?.appleClientId ? [item('Sign in with Apple…', () => groupTask(appleSignIn))] : []),
    item('New Group…', newGroup),
    item('Join with Code…', joinWithCode),
    ...(store.signedIn ? [item(store.myName ? `Change My Name (${store.myName})…` : 'Set My Name…', changeName)] : []),
    ...(store.signedIn && !store.anonymous ? [item('Sign Out of Groups', () => { core.leaveGroupTomato(); store.signOut(); })] : []),
    ...(store.signedIn && store.anonymous ? [item('Delete My Data…', deleteData)] : []),
    { type: 'separator' },
    item('Show friends focusing on the icon', () => { settings.set('hideFriendsCount', !settings.get('hideFriendsCount', false)); ui.render(); },
      { type: 'checkbox', checked: !settings.get('hideFriendsCount', false) }),
  ] };
}

const groupsOn = () => store instanceof GroupStore || !!shots;
// 0 = Sunday … 6 = Saturday, from this PC's region.
function firstWeekday() {
  const loc = new Intl.Locale(app.getLocale() || 'en-US'), day = (loc.getWeekInfo?.() ?? loc.weekInfo)?.firstDay ?? 7;
  return day % 7;
}

// MARK: Menu actions

const CANCEL = Symbol('cancel');

// Runs a group action; failures become one plain message, and nothing in the solo timer changes.
async function groupTask(work) {
  try { await work(); } catch (e) {
    if (e !== CANCEL) tell(e instanceof GroupError ? e.message : GroupError.text.offline);
  }
}

const tell = (message, detail = '') => dialog.showMessageBox({ type: 'info', title: 'Tomatime', message, detail, buttons: ['OK'] });
const confirm = async (message, detail, button) => (await dialog.showMessageBox(
  { type: 'question', title: 'Tomatime', message, detail, buttons: [button, 'Cancel'], defaultId: 0, cancelId: 1 })).response === 0;

async function customTomato() {
  const m = await askMinutes('Custom tomato', core.custom?.minutes);
  if (m != null) core.customTomato(m);
}

// While the group tomato runs: its length, for everyone in it. On the group break: the next round's tomato.
async function changeGroup(g, name, minutes) {
  if (name == null) {
    const m = await askMinutes('Custom group tomato', undefined, 'Change');
    if (m == null) return;
    [name, minutes] = [`${m}-min`, m];
  }
  if (!core.changeGroupTomato(g.id, name, minutes)) {
    tell("Can't change it to that now.", "The new length has to leave at least a minute, and not in this tomato's last 10 seconds. You can pick the next one on the red screen.");
  }
}

// Type your own Exam mode plan: tomatoes and breaks in order.
async function editExam() {
  const v = await askText('Exam mode plan', 'Minutes in order: tomato, break, tomato, break, … ending with a tomato. '
    + `Recommended: ${recommendedExamPlan.join(', ')}`, { value: core.examPlan.join(', '), button: 'Save', limit: 120 });
  if (v == null) return;
  const plan = parseExamPlan(v);
  if (!plan) return tell("That's not a plan.", 'Type whole minutes from 1 to 480, starting and ending with a tomato, like: 25, 8, 45, 10, 60');
  settings.set('examPlan', plan);
}

// No tomato name and length: Custom tomato…, which asks the minutes.
function startGroup(g, name, minutes) {
  return groupTask(async () => {
    if (name == null) {
      const m = await askMinutes('Custom group tomato');
      if (m == null) return;
      [name, minutes] = [`${m}-min`, m];
    }
    await store.startSession(g.id, name, minutes);
  });
}

// Signed in, with a display name. No account to make: the invite code and a name are enough.
async function readyForGroups() {
  if (!store.signedIn) await store.signInWithCode();
  if (await store.loadName() == null) {
    const name = await askText('Your name in groups', 'The others in your groups see this name. You can change it later.', { button: 'Save', limit: 30 });
    if (name == null) throw CANCEL;
    await store.setName(name);
  }
}

const newGroup = () => groupTask(async () => {
  await readyForGroups();
  const name = await askText('New group', 'A name for the group, like “Us” or “Physics 115”.', { button: 'Create', limit: 40 });
  if (name == null) return;
  const code = await store.createGroup(name);
  clipboard.writeText(code);
  tell(`Invite code copied: ${code}`, `Send it to up to ${maxGroupSize - 1} people. In Tomatime they choose Groups ▸ Join with Code….`);
});

const joinWithCode = () => groupTask(async () => {
  await readyForGroups();
  const code = await askText('Join a group', 'Type the invite code you were sent, like TOMA-4K7QM2.', { placeholder: 'TOMA-', button: 'Join', limit: 20 });
  if (code == null) return;
  const verdict = await store.join(code);
  tell({ ok: 'You’re in!', alreadyMember: 'You’re already in this group.', full: GroupError.text.full }[verdict],
    verdict === 'ok' ? 'The group is now in the Tomatime menu.' : '');
});

const changeName = () => groupTask(async () => {
  const name = await askText('Your name in groups', 'The others in your groups see this name.', { value: await store.loadName() ?? '', button: 'Save', limit: 30 });
  if (name != null) await store.setName(name);
});

const newCode = (g) => groupTask(async () => {
  if (!await confirm('Make a new invite code?', 'The old code stops working. People already in the group stay.', 'New Code')) return;
  const code = await store.newCode(g.id);
  clipboard.writeText(code);
  tell(`New invite code copied: ${code}`, 'Send it to the people you want to invite.');
});

const removeMember = (g, m) => groupTask(async () => {
  if (await confirm(`Remove ${m.name} from the group?`, 'They can come back only with a new invite.', 'Remove')) await store.remove(m.uid, g.id);
});

const renameGroup = (g) => groupTask(async () => {
  const name = await askText('Rename group', 'Everyone in the group sees the new name.', { value: g.name, button: 'Rename', limit: 40 });
  if (name != null) await store.rename(g.id, name);
});

const leaveGroup = (g) => groupTask(async () => {
  if (!await confirm(`Leave ${g.name}?`, 'You can come back later with an invite code, if there’s room.', 'Leave')) return;
  if (core.group.gid === g.id) core.leaveGroupTomato();
  await store.leave(g.id);
});

const deleteData = () => groupTask(async () => {
  if (!await confirm('Delete your Tomatime Groups data?', 'You leave all your groups, and your name, status and group minutes are deleted. '
    + 'Your tomato minutes on this PC stay. This can’t be undone.', 'Delete')) return;
  core.leaveGroupTomato();
  await store.deleteAccount();
  tell('Your Groups data is deleted.');
});

// Sign in with Apple in the person's own browser (apple.js). Afterwards this PC is one more device on their timer.
let appleWait;
async function appleSignIn() {
  appleWait?.cancel();
  const state = randomUUID(), rawNonce = newNonce(), wait = appleWait = waitForToken(state);
  try {
    await shell.openExternal(signInURL({ clientId: config.appleClientId, redirect: config.appleRedirect, port: await wait.ready, state, rawNonce }));
    const idToken = await wait.token;
    await store.signInWithApple(idToken, rawNonce);
  } catch (e) {
    if (['cancelled', 'timeout', 'user_cancelled_authorize'].includes(e.message)) throw CANCEL;
    throw e instanceof GroupError ? e : new GroupError('offline');
  }
}

// MARK: Windows

function small(file, data, width) {
  const w = new BrowserWindow({ width, height: 120, useContentSize: true, resizable: false, minimizable: false, maximizable: false,
    fullscreenable: false, show: false, alwaysOnTop: true, title: 'Tomatime', icon: appIcon, webPreferences: { preload } });
  w.removeMenu();
  w.loadFile(page(file), { query: { d: JSON.stringify(data) } });
  w.webContents.once('did-finish-load', async () => {  // as tall as what it says
    w.setContentSize(width, Math.ceil(await w.webContents.executeJavaScript('document.documentElement.offsetHeight')));
    w.center();
    if (!hidden) { w.show(); w.focus(); }
  });
  return w;
}

// One small question at a time. Resolves with { key: text } or null (Cancel, or the window closed).
let asking = null;
function ask(question) {
  asking?.win.close();
  return new Promise((resolve) => {
    const win = small('prompt.html', question, 400);
    const mine = asking = { win, answer(v) { if (asking === mine) asking = null; resolve(v); if (!win.isDestroyed()) win.destroy(); } };
    win.on('closed', () => mine.answer(null));
  });
}
ipcMain.handle('tomatime:prompt', (_e, values) => asking?.answer(values));

// A one-line answer, 1…limit characters; null = Cancel.
const askText = async (title, info, { value = '', placeholder = '', button, limit }) =>
  (await ask({ title, info, button, fields: [{ key: 'v', value, placeholder, limit }] }))?.v ?? null;

// A tomato's length in whole minutes, 1 to 480 (solo and group). null: cancelled.
async function askMinutes(title, value, button = 'Start') {
  const a = await ask({ title, info: `How many minutes? Up to ${maxFocusMinutes} (${maxFocusMinutes / 60} hours).`, button,
    fields: [{ key: 'v', value: value ?? '', placeholder: `Minutes, 1 to ${maxFocusMinutes}`, minutes: maxFocusMinutes }] });
  const m = Number(a?.v);
  return Number.isInteger(m) && m >= 1 && m <= maxFocusMinutes ? m : null;
}

// A see-through window over one whole display, above everything, for the countdown and the red end screen.
function overlay(file, data, bounds, main) {
  const w = new BrowserWindow({ ...bounds, frame: false, transparent: !shots, backgroundColor: shots ? '#3b6ea5' : '#00000000',
    resizable: false, movable: false, minimizable: false, maximizable: false, fullscreenable: false, skipTaskbar: true,
    hasShadow: false, roundedCorners: false, show: false, webPreferences: { preload, backgroundThrottling: false } });
  w.setAlwaysOnTop(true, 'screen-saver');
  w.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true, skipTransformProcessType: true });
  w.loadFile(page(file), { query: { d: JSON.stringify({ ...data, quiet: !main }) } });
  if (!hidden) w.once('ready-to-show', () => { w.setBounds(bounds); if (main) { w.show(); w.focus(); } else w.showInactive(); });
  return w;
}

// On every display; the main one takes the keyboard (Enter and Esc).
function overlays(file, data) {
  const first = screen.getPrimaryDisplay().id;
  return screen.getAllDisplays().map((d) => overlay(file, data, d.bounds, d.id === first));
}

ipcMain.handle('tomatime:countdown', (_e, what) => {
  const c = showing;
  if (!c) return;
  if (what === 'join') { tellAll(countdownWins, 'joined'); return core.joinRound(c.gid, c.sid); }
  closeAll(countdownWins); countdownWins = [];  // 'over': it ran out; the tomato starts (or not) by itself
  if (what === 'skip') core.skipRound(c.gid, c.sid);
  if (what === 'cancel') core.cancelRound(c.gid, c.sid);
});

// "groupBreak:2": the group break, and the next group tomato is the third of the four. "ok": Exam mode's break screen.
ipcMain.handle('tomatime:done', (_e, what) => {
  const [name, pick] = String(what).split(':');
  return ({
    groupBreak: () => core.groupBreak(pick == null ? null : Number(pick)), break5next: () => core.startBreak(5, true),
    break10next: () => core.startBreak(10, true), break5: () => core.startBreak(5), break10: () => core.startBreak(10),
    oneMore: () => core.oneMore(), end: () => core.resetTapped(), ok: () => ui.closeDone(),
  })[name]?.();
});

// MARK: Welcome (first run)

let welcomeWin;
function showWelcome() {
  welcomeWin = small('welcome.html', { apple: !!config?.appleClientId }, 460);
  welcomeWin.on('closed', () => { welcomeWin = null; settings.set('welcomed', true); });
}
const problem = (e) => ({ error: e === CANCEL ? '' : e instanceof GroupError ? e.message : GroupError.text.offline });

ipcMain.handle('tomatime:welcome:join', async (_e, { code, name }) => {
  try {
    if (!store.signedIn) await store.signInWithCode();
    if (name !== await store.loadName()) await store.setName(name);
    if (await store.join(code) === 'full') return { error: GroupError.text.full };
    const joined = () => store.groups.find((g) => store.code(g.id) === normalizeCode(code));
    for (let i = 0; i < 30 && !joined(); i++) await sleep(100);  // the group arrives a moment later
    return { group: joined()?.name ?? 'the group' };
  } catch (e) { return problem(e); }
});

ipcMain.handle('tomatime:welcome:apple', async () => {
  try {
    await appleSignIn();
    if (welcomeWin && !hidden) { welcomeWin.show(); welcomeWin.focus(); }
    const name = await store.loadName();
    await sleep(2000);  // their groups arrive a moment later
    return { name, groups: store.groups.map((g) => g.name) };
  } catch (e) { return problem(e); }
});

ipcMain.handle('tomatime:welcome:done', (_e, { openAtLogin }) => {
  if (app.isPackaged) app.setLoginItemSettings({ openAtLogin });
  welcomeWin?.close();
});

// MARK: Start

app.whenReady().then(async () => {
  settings = jsonFile('settings.json');
  const deviceID = settings.get('deviceID', randomUUID());
  settings.set('deviceID', deviceID);
  const deviceKey = `focus-${deviceID}`;
  try { config = JSON.parse(fs.readFileSync(path.join(here, 'firebase-config.json'), 'utf8')); } catch { config = null; }
  const saved = jsonFile('signin.json', { secret: true, delay: 0 });
  // Where Firebase keeps the sign-in between launches (the shape firebase/auth expects of a persistence class).
  class Saved {
    static type = 'LOCAL'; type = 'LOCAL';
    async _isAvailable() { return true; }
    async _set(key, value) { saved.set(key, value); }
    async _get(key) { return saved.get(key, null); }
    async _remove(key) { saved.set(key, undefined); }
    _addListener() {} _removeListener() {}
  }
  if (shots) store = sample();
  else if (emulator || config) store = new GroupStore({ config: emulator ? null : { apiKey: config.apiKey, projectId: config.projectId, authDomain: config.authDomain }, persistence: Saved, deviceKey });
  else store = { signedIn: false, anonymous: true, uid: null, groups: [], sessions: {} };  // no Firebase settings: the solo timer
  if (!shots && !(selftest && hidden)) tray = new Tray(trayImage('#e63326', '', false));  // the dev Mac stays untouched
  core = new Core({ store, settings, ui, deviceKey, unit: fast ? 1 : 60, emulator, idleSeconds: () => powerMonitor.getSystemIdleTime() });
  if (shots) return takeShots(shots);
  if (selftest) return selfTest().catch((e) => { console.error('SELFTEST FAILED:', e.message); app.exit(1); });
  const open = () => tray.popUpContextMenu(Menu.buildFromTemplate(menuTemplate()));  // built when opened: fresh "min left"
  tray.on('click', open);
  tray.on('right-click', open);
  ui.render();
  if (store instanceof GroupStore) {
    await store.start();
    if (!store.signedIn && !settings.get('welcomed', false)) showWelcome();
  }
});

// Quitting mid-tomato: count the minutes so far and give the last writes a moment to leave.
let quitting = false;
app.on('before-quit', (e) => {
  if (quitting || !core) return;
  quitting = true;
  e.preventDefault();
  core.quit();
  settings.flush();
  setTimeout(() => app.exit(), store.signedIn ? 800 : 0);
});

// MARK: --shots: the same drawing code with sample people, into files. Nothing appears on screen.

function sample() {
  const now = Date.now(), min = 60000, today = `${new Date().getFullYear()}-${new Date().getMonth() + 1}-${new Date().getDate()}`;
  const person = (uid, name, status, secs) => ({ uid, name, joinedAt: now - 30 * 86400000, hasPass: true, status,
    secondsByDevice: { d: { [today]: secs } } });
  const idle = { state: 'idle', tierName: '', minutes: 0, endsAt: null, sessionID: null };
  const g = { id: 'g1', name: 'Physics 115', ownerUID: 'me', memberUIDs: ['me', 'mina', 'alex'], unlocked: true, members: [
    person('me', 'Songgun', idle, 45 * 60),
    person('mina', 'Mina', { ...idle, state: 'focus', tierName: 'Golden', minutes: 45, endsAt: now + 31 * min }, 130 * 60),
    person('alex', 'Alex', { ...idle, state: 'break', minutes: 10, endsAt: now + 4 * min }, 75 * 60)] };
  return { signedIn: true, anonymous: true, uid: 'me', myName: 'Songgun', groups: [g], sessions: {}, code: () => 'TOMA-4K7QM2',
    publish() {}, publishSeconds() {}, writeTimer() {} };
}

async function takeShots(dir) {
  fs.mkdirSync(dir, { recursive: true });
  const save = (name, png) => fs.writeFileSync(path.join(dir, name), png);
  const icons = { idle: ['#e63326', '', false], running24: ['#e63326', '24', false], green7friends: ['#73c740', '7', true],
    diamond2h: ['#8ce0ff', '2h', false], break4: ['#8c9eb3', '4', true] };
  for (const [name, a] of Object.entries(icons)) {
    for (const size of [16, 32]) save(`icon-${name}-${size}.png`, nativeImage.createFromBitmap(tomatoBitmap(size, ...a), { width: size, height: size }).toPNG());
  }
  const text = (items, depth = 0) => items.map((i) => (i.type === 'separator' ? `${'  '.repeat(depth)}---` : i.visible === false ? null
    : `${'  '.repeat(depth)}${i.checked ? '✓ ' : ''}${i.label}${i.enabled === false ? '   (info)' : ''}${i.submenu ? '\n' + text(i.submenu, depth + 1) : ''}`))
    .filter((l) => l != null).join('\n');
  save('menu.txt', `${tip()}\n\n${text(menuTemplate())}\n`);
  const shot = async (name, w, wait = 700) => {
    if (w.webContents.isLoading()) await new Promise((r) => w.webContents.once('did-finish-load', r));
    await sleep(wait);
    save(`${name}.png`, (await w.webContents.capturePage(undefined, { stayHidden: true })).toPNG());
    w.destroy();
  };
  const full = { x: 0, y: 0, width: 1280, height: 800 }, start = Date.now() + 8400;
  const names = { joined: ['Mina'], waiting: ['You', 'Alex'] }, title = 'Physics 115: Mina started a 🍅 Red tomato · 25 min';
  await shot('welcome', small('welcome.html', { apple: true }, 460));
  await shot('ask-minutes', small('prompt.html', { title: 'Custom tomato', info: 'How many minutes? Up to 480 (8 hours).', button: 'Start',
    fields: [{ key: 'v', value: 90, minutes: 480 }] }, 400));
  await shot('ask-code', small('prompt.html', { title: 'Join a group', info: 'Type the invite code you were sent, like TOMA-4K7QM2.', button: 'Join',
    fields: [{ key: 'v', placeholder: 'TOMA-', limit: 20 }] }, 400));
  await shot('countdown-invite', overlay('countdown.html', { title, mode: 'invite', startAt: start, note: '', ...names }, full, true), 250);
  await shot('countdown-autojoin', overlay('countdown.html', { title, mode: 'autoJoin', startAt: start + 3000, note: 'Auto-join is on', joined: ['Mina', 'You'], waiting: ['Alex'] }, full, true), 250);
  await shot('countdown-starter', overlay('countdown.html', { title: 'Physics 115: You started a 🍅 90 min tomato', mode: 'starter', startAt: start + 6000, note: '', joined: ['You'], waiting: ['Mina', 'Alex'] }, full, true), 250);
  await shot('done-solo', overlay('done.html', { tierName: 'Red', color: '#e63326', focused: 25, today: '70 tomato minutes today', inGroup: false, canExtend: true }, full, true));
  await shot('done-group', overlay('done.html', { tierName: 'Golden', color: '#ffc21a', focused: 45, today: '90 tomato minutes today', inGroup: true, canExtend: true, groupBreak: 10 }, full, true));
  await shot('done-exam', overlay('done.html', { tierName: 'Golden', color: '#ffc21a', focused: 45, today: '', inGroup: false, canExtend: true, groupBreak: 10,
    exam: { title: 'Tomato 3 of 4 done!', sub: '20 min break, then a 45 min tomato.\nLeave your desk and walk, outside if you can. Phone stays in your pocket.', ok: 'OK', leave: 'Leave Exam mode' } }, full, true));
  app.exit(0);
}

// MARK: --selftest: a new person's first minutes, clicked through the real (hidden) windows against the emulators:
// welcome → join with code + name, a typed tomato → red screen → break, a group invite → Join → group tomato.
async function selfTest() {
  const log = [];
  const ok = (what) => { console.log('ok   ', what); log.push(`ok    ${what}`); if (snaps) fs.writeFileSync(path.join(snaps, 'selftest.log'), log.join('\n') + '\n'); };
  if (snaps) fs.mkdirSync(snaps, { recursive: true });
  // A photo of the whole main display: what a person at this PC would see right now.
  const snap = async (name) => {
    if (!snaps) return;
    await sleep(700);
    const d = screen.getPrimaryDisplay(), size = { width: Math.round(d.size.width * d.scaleFactor), height: Math.round(d.size.height * d.scaleFactor) };
    const [source] = await desktopCapturer.getSources({ types: ['screen'], thumbnailSize: size });
    if (source) fs.writeFileSync(path.join(snaps, `${name}.png`), source.thumbnail.toPNG());
  };
  const until = async (what, cond, ms = 10000) => {
    for (const t0 = Date.now(); Date.now() - t0 < ms; await sleep(50)) if (await cond()) return ok(what);
    throw new Error(`timed out waiting for: ${what}`);
  };
  const js = async (w, code) => {
    if (w.webContents.isLoading()) await new Promise((r) => w.webContents.once('did-finish-load', r));
    return w.webContents.executeJavaScript(code, true);
  };
  const click = (w, selector) => js(w, `document.querySelector(${JSON.stringify(selector)}).click()`);
  const lines = (items) => items.flatMap((i) => [i.label, ...lines(i.submenu ?? [])]);

  const owner = new GroupStore({ config: null, deviceKey: 'focus-selftest-owner' });
  await owner.start(); await owner.signInWithCode(); await owner.setName('Owner');
  const code = await owner.createGroup('Self Test');
  await store.start();
  if (store.signedIn || settings.get('welcomed', false)) throw new Error('not a fresh start');

  showWelcome();
  await js(welcomeWin, `document.getElementById('code').value = ${JSON.stringify(code.toLowerCase())}; document.getElementById('name').value = 'Windows PC'`);
  await snap('1-welcome');
  await click(welcomeWin, '#go');
  await until('welcome: joined with code + name', () => js(welcomeWin, `document.getElementById('in').textContent === 'You’re in Self Test!'`));
  await snap('2-welcome-joined');
  await click(welcomeWin, '#done');
  await until('welcome closes and is not shown again', () => !welcomeWin && settings.get('welcomed', false));
  const gid = store.groups[0].id;
  await until('the owner sees the PC in the group', () => owner.groups[0]?.members.map((m) => m.name).join() === 'Owner,Windows PC');
  await until('menu shows the group, its people and Start group tomato', () => {
    const all = lines(menuTemplate());
    return ['👥 Self Test · 2 members', '💤 Windows PC (you) · 0 min today', 'Start group tomato', `Copy invite code (${code})`, 'Delete My Data…'].every((l) => all.includes(l));
  });

  const typed = customTomato();
  await until('the minutes question opens', () => !!asking);
  await js(asking.win, `document.querySelector('input').value = '2'`);
  await snap('3-custom-minutes');
  await click(asking.win, '#ok');
  await typed;
  await until('a typed 2-minute tomato runs', () => core.custom?.minutes === 2 && core.end != null);
  await until('the owner sees it', () => owner.groups[0].members[1].status.tierName === '2-min');
  await until('red screen when it ends', () => doneWins.length > 0);
  await until('red screen says what was done', () => js(doneWins[0], `document.getElementById('title').textContent === '2-min tomato done!' && document.getElementById('together').hidden`));
  await snap('4-red-screen');
  await click(doneWins[0], '[data-pick="break5"]');
  await until('"5 min break" starts a break and closes the red screen', () => core.onBreak && core.end != null && doneWins.length === 0);
  core.resetTapped();

  await owner.startSession(gid, 'Red', snaps ? 0.2 : 0.1);  // a 6-second group tomato (12 with photos)
  await until('group countdown appears as an invite', () => countdownWins.length > 0 && showing?.mode === 'invite');
  const sid = showing.sid;
  await until('countdown names who is in', () => js(countdownWins[0], `document.getElementById('names').textContent === 'Owner ✓ · You …' && !document.getElementById('join').hidden`));
  await snap('5-countdown-invite');
  await click(countdownWins[0], '#join');
  await until('Join reaches the group', () => owner.sessions[gid]?.joined.length === 2);
  await until('the Join button goes away', () => js(countdownWins[0], `document.getElementById('join').hidden`));
  await until('the group tomato starts on this PC', () => core.group.sid === sid && core.end != null, 15000);
  if (Math.abs(core.end - (store.sessions[gid].startAt + (snaps ? 12000 : 6000))) > 50) throw new Error('the group tomato does not end with the group');
  ok('it ends at the group\'s second');
  await until('the countdown closes by itself', () => countdownWins.length === 0);
  await until('red screen offers the group break', () => doneWins.length > 0 && js(doneWins[0], `!document.getElementById('together').hidden`), 12000);
  await snap('6-red-screen-group');
  await click(doneWins[0], '[data-pick="groupBreak"]');
  await until('the group break is on', () => core.onBreak && owner.sessions[gid]?.nextJoined.includes(store.uid));
  core.resetTapped();
  if (tray) { ui.render(); ok(`tray icon is up: "${tip()}"`); await snap('7-desktop-after'); }
  console.log('SELFTEST PASSED');
  app.exit(0);
}
