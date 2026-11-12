# Tomatime on iPhone + Apple Watch — test version

2026-11-11. Status: test version for the owner's own Mac, iPhone and Watch (TestFlight). The owner skipped
further questions ("first let's finish it for a version to test"); calls marked *(my call)* are open to change.

## Why

The owner studies with the Mac menu-bar timer and wants the phone and watch to join in: the countdown on the
watch face even with the screen dimmed, and the phone quiet ("Dumb Mode": only chosen apps may notify) while a
tomato runs. Later this ships to everyone; the iPhone app must also work on its own (no Mac).

## What the test version does

- **iPhone app:** pick Green 20 / Red 25 / Golden 45 / Diamond 60, Start, Pause/Resume, Stop. Big countdown.
  A notification with sound when a tomato ends. Works signed out (this phone only).
- **Watch app:** the same picker and buttons; countdown; a tap on the wrist when the tomato ends.
- **Countdown everywhere:** a Live Activity on the iPhone lock screen and Dynamic Island, which watchOS 11+
  also shows in the watch Smart Stack (dimmed in Always On); plus a watch-face complication with the
  countdown *(my call: the complication is the one thing Always On always shows)*.
- **Mac, iPhone, Watch are equals:** start/pause/resume/stop (and the Mac's breaks) on any device and the other
  two follow within seconds. Sync needs Sign in with Apple (the same account as Groups) on Mac and iPhone; the
  watch goes through the iPhone.
- **Dumb Mode:** a Focus named "Tomato" (the owner sets which apps may notify) is on while a focus tomato runs
  and off on pause, stop, break or end. Apple has no API to switch a Focus, so in the test version the Mac
  switches it with a Shortcut and "Share Across Devices" carries it to the iPhone and Watch.
- **Icons:** the new hand-drawn tomato (store/logo-source.jpeg) on all three.

## Not in the test version

iPhone calendar and Groups; Dumb Mode with no Mac (needs a Shortcuts-based flow on the phone); paid passes;
App Check; App Store release of the iPhone app.

## How it is built *(my calls)*

- **One timer document per person:** Firestore `users/{uid}/timer/current` =
  `{phase: focus|break|idle, tier, minutes, running, endAt (unix s, when running), left (s, when paused),
  by (device id), at (unix s)}`. Every change by a person writes it; every device applies changes whose `by`
  is not itself. Last write wins.
- **Devices:** `users/{uid}/devices/{deviceId}` = `{platform: ios|watchos|macos, apns, pushToStart,
  activity, env}`, tokens as hex. Only the owner can read/write both (security rules).
- **Push sender:** a Cloud Function (Firebase Blaze plan, `maxInstances: 5`) on writes to the timer document
  calls APNs directly with the owner's .p8 key (Firebase secret). For each device other than `by`:
  - iPhone: a background push carrying the timer (schedules/cancels the end notification), and a Live Activity
    push: update/end to the `activity` token, or push-to-start when there is none.
  - Watch: a background push carrying the timer (updates the app, complication, end notification).
  - Mac: nothing (it listens to the document while running).
- **Watch ↔ iPhone:** WatchConnectivity. Watch actions go to the iPhone, which writes them with `by` = the
  watch's id, so the server starts the iPhone's Live Activity (an app in the background cannot). The iPhone
  passes the watch's push token up to `devices`. Firestore does not run on watchOS (no gRPC / low-level
  networking), hence the relay.
- **Live Activity starts:** a device's own action starts its Live Activity locally; changes from elsewhere
  arrive by push. The content state stores `endAt` as unix seconds (a `Date` would decode from 2001-based
  seconds).
- **Mac Focus switch:** a shell script in `~/Library/Application Scripts/com.sgjlee.tomatime/focus.sh`
  (`shortcuts run "Tomatime $1"`), run with `NSUserUnixTask` — the sandbox-approved way. For the test version
  it is installed by hand; for everyone, Tomatime will offer to install it with a save panel.
- **Targets:** XcodeGen adds `TomatimeiOS` (bundle `com.sgjlee.tomatime`, same as the Mac app for universal
  purchase), `TomatimeLive` (widget extension), `TomatimeWatch` (`com.sgjlee.tomatime.watchkitapp`) and
  `TomatimeWatchWidget`. App Group `group.com.sgjlee.tomatime`. iOS 18.0, watchOS 11.0. Automatic signing with
  the App Store Connect API key. The iOS platform is added to the existing app record through the API.
- **Version:** Mac and iPhone both 1.2 (7).

## What the owner does

Firebase Blaze plan with a $1 budget alert; an APNs key (.p8 + Key ID); a "Tomato" Focus with Share Across
Devices; two Shortcuts ("Tomatime On": Set Focus Tomato on; "Tomatime Off": turn Tomato off); on the watch,
Return to Clock → Tomatime → 1 hour; then the TestFlight checklist.
