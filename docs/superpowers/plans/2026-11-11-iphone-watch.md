# Tomatime iPhone + Watch (test version) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan
> task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A TestFlight build where Mac, iPhone and Apple Watch share one tomato timer, with the countdown on
the iPhone lock screen, the watch (Smart Stack + complication) and a "Tomato" Focus switched by the Mac.

**Architecture:** One Firestore document per person (`users/{uid}/timer/current`) is the timer. Mac and
iPhone write and listen. A Cloud Function pushes every change to the other devices through APNs: background
pushes to the iPhone and Watch apps, Live Activity pushes to the iPhone. The watch talks to Firebase only
through the iPhone (WatchConnectivity).

**Tech Stack:** Swift 5 / SwiftUI / ActivityKit / WidgetKit / WatchConnectivity, firebase-ios-sdk 13 (Auth,
Firestore), Cloud Functions for Firebase v2 (Node 22, firebase-admin), APNs over HTTP/2 with a .p8 key,
XcodeGen.

**Spec:** docs/superpowers/specs/2026-11-11-iphone-watch-design.md

## Global Constraints

- Bundle ids: iOS app `com.sgjlee.tomatime` (same as Mac), widget `com.sgjlee.tomatime.live`, watch app
  `com.sgjlee.tomatime.watchkitapp`, watch widget `com.sgjlee.tomatime.watchkitapp.widget`.
  App Group `group.com.sgjlee.tomatime`. Team 976B3SJZGY.
- iOS 18.0, watchOS 11.0, macOS 14.0. Version 1.2, build 7 for every target.
- Tiers: Green 20, Red 25, Golden 45, Diamond 60 (minutes). Focus never over 60 min.
- Times are unix seconds (Double) everywhere in the timer document and the Live Activity content state.
- Secrets never in git: GoogleService-Info.plist, the APNs .p8, asc.env.
- The Mac keeps manual signing (TOMATIME_* settings); the new targets use automatic signing.
- No automated UI testing on devices: stage builds and ask the owner to test.

## Review Focus

1. Echo loops: a device applying a remote change must not write it back (`by` check + an "applying" guard).
2. Two Live Activities for one tomato (a local start plus a server push-to-start): the server never sends
   Live Activity pushes to the device named in `by`.
3. A paused timer resumed on another device: `left` must carry over; `endAt` recomputed from the resumer's clock.
4. Stale tokens: APNs 410/400 BadDeviceToken must clear that token, not crash the function or retry forever.
5. Signed out: every app still works alone; nothing is written.

---

### Task 1: Shared timer model

**Files:** Create `Shared/TomatoTimer.swift`; modify `Tests/RulesCheck.swift`, `tools/test.sh` (compile the new file into rulescheck).

**Interfaces — Produces:**
```swift
enum TimerPhase: String, Codable { case focus, rest = "break", idle }
struct TimerState: Codable, Equatable, Hashable {
    var phase: TimerPhase; var tier: String; var minutes: Double; var running: Bool
    var endAt: Double?; var left: Double; var by: String; var at: Double
    static func start(tier: String, minutes: Double, phase: TimerPhase, by: String, now: Date) -> TimerState
    static func idle(by: String, now: Date) -> TimerState
    func paused(by: String, now: Date) -> TimerState      // left = remaining, endAt nil, running false
    func resumed(by: String, now: Date) -> TimerState     // endAt = now + left
    func remaining(now: Date) -> Double                    // never below 0
    func focusModeOn(now: Date) -> Bool                    // focus && running && endAt > now
    var data: [String: Any] { get }                        // Firestore fields (endAt NSNull when nil)
    init?(data: [String: Any])
}
let tomatoTiers: [(name: String, minutes: Double)]
```

- [ ] Step 1: tests in RulesCheck: start Red at t → endAt t+1500, remaining(t+100)=1400; paused at t+100 →
  left 1400, running false, endAt nil; resumed at t+500 → endAt t+1900; remaining never negative;
  focusModeOn true only for running focus before endAt (false for break, paused, idle, after end);
  `TimerState(data: s.data) == s` for running and paused; `init?(data:)` nil for a missing phase.
- [ ] Step 2: run `tools/test.sh` → FAIL (TimerState undefined).
- [ ] Step 3: implement; add `Shared/TomatoTimer.swift` to the rulescheck compile line.
- [ ] Step 4: `tools/test.sh` → rules ok ×2, node tests pass.
- [ ] Step 5: commit "Shared timer model".

### Task 2: Security rules for the timer and devices

**Files:** `firebase/firestore.rules`, `firebase/rules.test.mjs`.

- [ ] Step 1: tests: owner can set/get `users/u/timer/current` and `users/u/devices/d`; another user cannot
  read or write either; signed-out cannot.
- [ ] Step 2: run → FAIL (subcollections denied). Step 3: add `match /{sub=**}` under `/users/{uid}` for the
  owner. Step 4: run → pass. Step 5: commit "Rules: timer + devices".

### Task 3: Push sender (Cloud Function)

**Files:** Create `firebase/functions/{package.json,index.js,push.js,apns.js,push.test.mjs}`; modify
`firebase/firebase.json` (functions source), `tools/test.sh` (run push.test.mjs).

**Interfaces — Produces:** `pushesFor(state, devices, nowSec) -> [{deviceId, field, token, env, topic, type,
priority, payload}]` (pure). `field` names the token to clear when APNs answers 410 / BadDeviceToken.
`send(push, key) -> {status, reason}` (HTTP/2 to api[.sandbox].push.apple.com, ES256 JWT, team 976B3SJZGY).

Rules of `pushesFor`, for each device whose id ≠ `state.by`:
- `ios`: background push `{aps:{content-available:1}, timer: state}` to `apns` (topic `com.sgjlee.tomatime`,
  type background, priority 5). Live Activity (topic `com.sgjlee.tomatime.push-type.liveactivity`, type
  liveactivity, priority 10), content state `{phase, tier, minutes, running, endAt, left}` (endAt 0 when nil):
  idle → `end` to `activity` (if any, dismissal-date now); otherwise `update` to `activity`, or `start` to
  `pushToStart` with `attributes-type: "TomatoActivity"`, `attributes: {}`, `input-push-token: 1` and an alert
  (`"🍅 Red tomato"` / `"25 min focus"`; break: `"☕ Break"` / `"5 min"`; paused: `"Paused"`).
  Running: `stale-date` = endAt.
- `watchos`: background push `{aps:{content-available:1}, timer: state}` to `apns` (topic
  `com.sgjlee.tomatime.watchkitapp`).
- `macos` and devices without tokens: nothing.

- [ ] Step 1: push.test.mjs: start from Mac → iPhone gets background + liveactivity start (no activity token)
  or update (with token); Mac and the `by` device get nothing; idle → end only when an activity token exists;
  watch gets one background push; `field` set right.
- [ ] Step 2: run → FAIL. Step 3: implement push.js, apns.js, index.js (`onDocumentWritten("users/{uid}/timer/current")`,
  `maxInstances: 5`, secrets `APNS_KEY`, `APNS_KEY_ID`; clears dead tokens). Step 4: run → pass.
- [ ] Step 5: commit "Push sender".

### Task 4: Mac joins the shared timer + Focus switch

**Files:** Create `Groups/TimerSync.swift` (extension App); modify `Groups/GroupStore.swift` (timer listen/write,
device doc, delete on account deletion), `main.swift` (call sites), `tools/test.sh` if needed.

**Interfaces — Consumes:** Task 1. **Produces:** `App.publishTimer()`, `App.applyRemote(_ s: TimerState)`,
`App.syncFocusMode()`; `GroupStore.writeTimer(_:)`, `GroupStore.onTimer: ((TimerState) -> Void)?`.

- Publish after every local change: `run()` (start, resume, break, one more, custom), the pause path of
  `toggle()`, `reset()` (idle). Not while applying a remote change. Only when signed in and real minutes.
- Remote state with `by` ≠ this Mac: focus/break running → set tier (custom Tier when the name is not a tier),
  `onBreak`, `run(remaining)`; paused → `left`, stop; idle → `reset()`. Close the red overlay first.
- Focus switch: `focusModeOn(now:)` of the current state; on change run `focus.sh On|Off` from the
  Application Scripts folder with `NSUserUnixTask` (silently nothing if the script is missing).
- [ ] Step 1: emulator check (fake second device via a node script writing the timer doc): Mac follows start,
  pause, resume, stop; Mac's own start lands in Firestore with its `by`. Stage for the owner as needed.
- [ ] Step 2: commit "Mac: shared timer + Focus switch".

### Task 5: iPhone app + Live Activity

**Files:** `project.yml` (targets TomatimeiOS, TomatimeLive), `iOS/` (App, TimerModel, ContentView, Push,
WatchRelay, entitlements, Info), `Live/` (widget bundle + views), `Shared/TomatoActivity.swift`
(`TomatoActivity: ActivityAttributes`, ContentState `{phase, tier, minutes, running, endAt, left}`),
`iOS/Assets.xcassets` (AppIcon from the new art).

- Local action: update state, schedule/cancel the end notification, start/update/end the Live Activity
  locally, write the timer (signed in), tell the watch (applicationContext).
- Remote state (listener in foreground, background push): same, except Live Activities (the server does them).
- Registers: APNs token, push-to-start token, each activity's push token → `devices/{id}` (`platform ios`,
  `env` production unless DEBUG).
- Watch messages: `start/pause/resume/stop` → write with `by` = the watch's id; `token` → `devices/{watchId}`.
- [ ] Step 1: `xcodebuild -scheme TomatimeiOS -sdk iphonesimulator build` → succeeds. Step 2: commit.

### Task 6: Watch app + complication

**Files:** `project.yml` (TomatimeWatch, TomatimeWatchWidget), `Watch/`, `WatchWidget/`.

- Picker → countdown → Pause/Resume/Stop. Sends actions to the iPhone (sendMessage, else transferUserInfo).
- Background push and applicationContext → state in the App Group, end notification, complication reload.
- Complication families: circular, rectangular, corner, inline; `Text(timerInterval:)` while running.
- [ ] Step 1: build for the watch simulator → succeeds. Step 2: commit.

### Task 7: Ship to TestFlight + backend

- [ ] Rules + function deploy (needs Blaze + APNs key; key as secrets).
- [ ] Add the iOS platform to app 6832374095 (API). Archive + upload iOS (with watch) and Mac 1.2 (7).
- [ ] Install `focus.sh` in `~/Library/Application Scripts/com.sgjlee.tomatime/`.
- [ ] Owner checklist (literal steps): Focus "Tomato" + Share Across Devices, two Shortcuts, Return to Clock
  1 hour, install, sign in on Mac and iPhone, start on each device, pause elsewhere, watch Always On.
