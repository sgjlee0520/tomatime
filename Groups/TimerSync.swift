// The shared timer: this Mac follows the person's iPhone and Watch, and they follow it. One Firestore document
// (Shared/TomatoTimer.swift); the Cloud Function in firebase/functions pushes it to the phone and watch.
// Also switches the "Tomato" Focus ("Dumb Mode"), which Share Across Devices carries to the iPhone and Watch.
import AppKit

extension App {
    // After every local change. Not while following another device, and only for signed-in, real-minute timers.
    func publishTimer(idle: Bool = false) {
        guard groupsOn, !applyingRemote, store.signedIn, unit == 60 || useEmulator else { return }
        let now = Date()
        let s = idle ? TimerState.idle(by: deviceKey, now: now)
            : TimerState(phase: onBreak ? .rest : .focus, tier: onBreak ? "Break" : tier.name,
                         minutes: onBreak ? breakMinutes : focused, running: end != nil,
                         endAt: end?.timeIntervalSince1970, left: left, by: deviceKey, at: now.timeIntervalSince1970)
        guard !sameTimer(shared, s) else { return }
        shared = s
        store.writeTimer(s)
    }

    // A change from my phone or watch (or another Mac).
    func applyRemote(_ s: TimerState) {
        guard s.by != deviceKey, !sameTimer(shared, s) else { return }
        shared = s
        let now = Date()
        if s.running, (s.endAt ?? 0) <= now.timeIntervalSince1970 { return }  // already over (e.g. seen at launch)
        applyingRemote = true
        defer { applyingRemote = false }
        leaveGroupTomato()
        closeOverlay()
        guard s.phase != .idle else { return reset() }
        onBreak = s.phase == .rest
        autoNext = false
        if onBreak {
            breakMinutes = s.minutes
        } else {
            if let i = tiers.firstIndex(where: { $0.name == s.tier && $0.minutes == s.minutes }) {
                tierIndex = i
                custom = nil
            } else {
                custom = Tier(name: s.tier, minutes: s.minutes,
                              color: tiers.last { $0.minutes <= s.minutes }?.color ?? tiers[0].color)
            }
            focused = s.minutes
        }
        if s.running, let e = s.endAt {
            run(e - now.timeIntervalSince1970)
        } else {
            countFocus()
            stop()
            left = s.left
            render()
        }
    }

    // "Dumb Mode": the Tomato Focus is on while a focus tomato runs here. Apple has no API for Focus, so this
    // runs ~/Library/Application Scripts/com.sgjlee.tomatime/focus.sh On|Off (it calls the Shortcuts
    // "Tomatime On" / "Tomatime Off"); the sandbox allows scripts the person put there. No script: nothing.
    func syncFocusMode() {
        let on = !onBreak && (end.map { $0 > Date() } ?? false)
        guard on != focusModeOn else { return }
        focusModeOn = on
        guard let dir = try? FileManager.default.url(for: .applicationScriptsDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: false),
              let task = try? NSUserUnixTask(url: dir.appendingPathComponent("focus.sh")) else { return }
        task.execute(withArguments: [on ? "On" : "Off"]) { _ in }
    }
}

