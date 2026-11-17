# Tomatime for Windows: design

2026-11-14. A Windows version of Tomatime so the owner's study partners can join the owner's groups.

Marking: **(user)** = the owner decided it. **(my call)** = my default; the owner hasn't weighed in.

## Why

The owner studies with partners and study groups, and Tomatime Groups (Mac 1.2) lets people focus together: see
who's focusing, start a tomato at the same second, take the break together, compare minutes. Some partners use
Windows laptops and can't join. The Windows app exists for them (user: "windows version is for study partners
joining my group"). It is not, for now, a product for Windows users at large.

The owner's own setup (Mac + iPhone + Apple Watch on one shared timer, Sign in with Apple) is the priority and must
not change or get worse (user).

## Success

A partner on a Windows laptop:
1. downloads Tomatime from the website (Windows button) and installs it;
2. types the invite code the owner sent and a display name, and is in the group (no account, no password);
3. sees the group in the tray menu: who's focusing (tomato, minutes left), on a break, or idle (minutes today);
4. when anyone starts a group tomato, gets the 10-second countdown on every monitor, clicks Join, and starts at the
   same second as the Mac members;
5. at the end, gets the red screen and can take the 10-minute group break with everyone, then the next round;
6. shows up correctly on the Mac members' side (status, joined names, countdowns, minutes in the group calendar and
   weekly ranking).

## Goals

- Full participation in Groups, identical behaviour to the Mac app (Groups/ and main.swift are the reference).
- A solo timer too: the same four tomatoes (Green 20, Red 25, Golden 45, Diamond 60) and custom length, the red end
  screen, breaks. Partners' solo tomatoes show as "focusing" in the group, as Mac members' do (my call: a partner
  who can only do group tomatoes would look idle most of the time).
- Timer in the system tray (user asked where it goes; tray it is).
- Free, like the rest of Tomatime.

## Non-goals (v1)

- ~~Syncing with iPhone/Apple Watch, and Sign in with Apple.~~ Changed 2026-11-15 (user: "can we make it so that
  people who use iphon+applewatch+windows pc can have the same experience"; then "windows"): the Windows app has two
  ways in. Invite code + name as below, and Sign in with Apple in the person's browser (windows/apple.js), which
  signs in the same account as on their iPhone, Watch and Mac, so the PC follows the same shared timer. It needs a
  Services ID at Apple (the owner creates it) and is switched on by `appleClientId` in windows/firebase-config.json.
- The full Tomato Calendar window (my call): v1 shows today's minutes and this week's group ranking in the menu.
  The month calendar comes later if partners ask.
- The Mac's "Tomato" Focus mode / Shortcuts hook, Open at Login nag, in-app purchases (groups are free:
  `groupsFree`).
- Mac or Linux builds for users (the same code runs there; we use that only for testing).

## Anti-goals: failure even if it works

- **Anything that changes or breaks the owner's Mac/iPhone/Watch setup**, including the Firestore data format and
  the security rules. The Windows app writes exactly what the Mac app writes.
- **Nothing starts unless the partner chose it**: Join, or auto-join turned on for that group (same as Mac).
- **The countdown must not hide their work**: the workspace stays visible behind it (same as Mac).
- **A partner who loses track of the tray icon loses the app.** Windows 11 hides new tray icons; first run must
  get the icon pinned or make the timer findable another way.

## Constraints

- **Same Firebase project** ("tomatimer": Auth + Firestore). Data model is fixed by the Mac app:
  `codes/{code}`, `groups/{gid}` (+ `members/{uid}`, `sessions/{sid}`), `users/{uid}`. Field names, types,
  device keys (`secondsByDevice`: device → dayKey → seconds) and the session/round logic must match
  Groups/GroupStore.swift and Groups/GroupRules.swift exactly. firebase/firestore.rules must not change.
- **Sign-in = invite code + name** (user, "invite code + name"): Firebase Anonymous Auth. The rules only require
  `request.auth != null`, so no rule change. Anonymous sign-in must be switched on in the Firebase project (one
  setting). One partner = one install: a reinstall or second PC makes a new member (accepted trade-off; Google or
  web Apple sign-in can be added later and linked to the anonymous account).
- **Windows 10 and 11.** Multiple monitors, mixed scaling (100–200%).
- **No code-signing certificate** at first: Windows SmartScreen will warn ("Windows protected your PC"). The
  website says how to get past it (More info → Run anyway). The Microsoft Store (free for individuals) removes the
  warning later; the owner registers, I do the rest.
- **Test machines:** this Mac (the same app code runs on macOS against the local Firebase emulators with
  firebase/tools/friends.mjs playing Mina and Alex), GitHub Actions Windows runners (free for the public repo:
  build, automated checks, screenshots of the tray, countdown and red screen on real Windows), the owner's other AI
  on Linux (a real second person in a group; or a Windows 11 evaluation VM if its machine can virtualise), and one
  study partner on a real Windows laptop before it's announced.
- Firebase quota: Blaze plan with a $1 budget alert. Writes only on state changes (as Mac).

## Approaches

| Approach | Download | Trade-off |
|---|---|---|
| **Electron + Firebase JS SDK (chosen)** | ~90 MB | Google's official Firebase client (the one firebase/tools already uses), so group sync is the most reliable; mature tray, multi-monitor transparent always-on-top windows, login item; runs on Windows, Linux and Mac, which is what makes the testing plan above work; builds with electron-builder on GitHub Actions; web Sign in with Apple later is straightforward. |
| Tauri + Firebase JS SDK | ~8 MB | Same JS code in Windows' built-in WebView2, much smaller download; rougher tray/overlay/pop-up sign-in support and a Rust toolchain. |
| Native C# (WinUI/WPF) | small | Most Windows-native, but no official Firebase client SDK for Windows desktop: sync would be hand-written over REST/gRPC. Most work, most risk. |

Chosen: Electron (my call, presented to the owner, who didn't object; their test machine being Linux makes the
cross-platform property matter more). Partners download it once, so size is the cheaper trade.

## The experience

### First run
1. Installer (NSIS, per-user, no admin) → Tomatime starts, tray icon appears.
2. A small welcome window: "Join your study group" → invite code field (TOMA-…) and "Your name" field → Join.
   Anonymous sign-in happens here, silently. Wrong code / full group / offline → plain message in the window.
3. The welcome window then shows how to keep the tomato visible in the taskbar on Windows 11 (drag it out of ^,
   or Settings → Personalization → Taskbar → Other system tray icons) with a picture, and an "Open at login"
   checkbox (on by default, my call: partners must be reachable for invites).

### Tray
- Icon: the tomato in the current tier's colour with the minutes left drawn on it while running ("24"); plain
  tomato when idle. A small badge dot when friends are focusing (Mac shows a count in the menu bar; my call to
  mirror it as a dot or number on the icon). Tooltip: "Red tomato · 24:12 left" / "Physics 115: 2 focusing".
- Left- or right-click opens the menu, mirroring the Mac menu: today's minutes; each group with members and their
  status, Start group tomato / Join / group break line, Auto-join, Copy invite code, This week's ranking, Leave
  group; Join another group…; Start / Pause / Reset; the four tomatoes + Custom…; Change my name…; Open at login;
  Delete my data…; Quit.

### Countdown, group tomato, group break
Same as Mac (Groups/Countdown.swift): 10-second countdown on every monitor with the starter, tomato and joined /
waiting names, Join (Enter) and Skip; workspace visible behind; auto-join if turned on and the PC was used in the
last 2 minutes (activeMacSeconds). The group break is 10 minutes, then another countdown for those who picked it.

### Red end screen
Same as Mac: translucent red over every monitor, the card with the tomato, "Red tomato done!", "You focused N min ·
M tomato minutes today", and the same choices (group: "10 min break, then next group tomato"; solo: 5/10 min
break then next session, 5 / 10 min break, 1 more minute (never past 60), End session). Reduce Motion: no pulse.

### Leaving and deleting
Leave group (as Mac rules allow). "Delete my data…" removes this person's member docs and users doc and deletes
the anonymous account (no Apple token to revoke).

## How it fits together (for the builder)

- `windows/` folder in the tomatime repo (my call): Electron main process (tray, windows, timers, login item),
  a renderer for the welcome/countdown/red-screen windows, and a shared `rules.js` ported 1:1 from
  Groups/GroupRules.swift (sessionPhase, countdownMode, statusText, weeklyRanking, nextRoundStart, memberSeconds,
  dayKey…) with `node --test` checks mirroring Tests/RulesCheck.swift, plus the Firestore read/write layer ported
  from Groups/GroupStore.swift.
- Firebase config: the web app config for project tomatimer (public values; register a Web app in the project).
- Builds: GitHub Actions on windows-latest → installer + `latest.yml` on a GitHub Release; electron-updater checks
  that release for updates (my call: partners shouldn't have to re-download fixes by hand).
- Website: the Windows button links to the latest release once v1 passes the partner test.
- `--emulator` and `--fast` flags like the Mac app, for the testing plan.

## Settled after the builder check (my calls)

- **Live-project setup** (switch on Anonymous sign-in, register a Web app for the Firebase config) is a step in the
  plan: done with the Firebase CLI / APIs under the owner's login where possible, otherwise two console clicks by
  the owner.
- **`hasPass`:** Windows writes what the Mac writes today (`hasPass: groupsFree`, i.e. true). When Mac groups
  become paid, Windows joining needs revisiting; groups that exist stay unlocked either way.
- **Test tooling:** friends.mjs waits for someone to create a group, and the Windows app only joins. Add a `create`
  command to firebase/tools/fake-member.mjs (or run the Mac app with `--emulator`) so a test group exists for the
  Windows app to join.

## Left to the builder

Process layout inside Electron, UI framework (plain HTML/CSS is enough), how the tray digits are drawn, how
"used in the last 2 minutes" is detected on Windows, installer details, the exact welcome-window copy within the
voice of the Mac app.
