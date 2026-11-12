// The one tomato timer a person's Mac, iPhone and Apple Watch all follow. Stored in Firestore at
// users/{uid}/timer/current and sent to the iPhone/Watch in pushes (firebase/functions/push.js reads the same
// field names). Times are unix seconds. Foundation only: compiled into every target and into rulescheck.
import Foundation

let tomatoTiers: [(name: String, minutes: Double)] = [("Green", 20), ("Red", 25), ("Golden", 45), ("Diamond", 60)]

enum TimerPhase: String, Codable { case focus, rest = "break", idle }

struct TimerState: Codable, Equatable, Hashable {
    var phase: TimerPhase
    var tier: String
    var minutes: Double
    var running: Bool
    var endAt: Double?  // while running
    var left: Double    // seconds, while paused
    var by: String      // device id that made this change
    var at: Double      // when

    static func start(tier: String, minutes: Double, phase: TimerPhase, by: String, now: Date) -> TimerState {
        TimerState(phase: phase, tier: tier, minutes: minutes, running: true,
                   endAt: now.timeIntervalSince1970 + minutes * 60, left: minutes * 60, by: by, at: now.timeIntervalSince1970)
    }

    static func idle(by: String, now: Date) -> TimerState {
        TimerState(phase: .idle, tier: "", minutes: 0, running: false, endAt: nil, left: 0, by: by, at: now.timeIntervalSince1970)
    }

    func paused(by: String, now: Date) -> TimerState {
        var s = self
        s.left = remaining(now: now)
        s.running = false
        s.endAt = nil
        s.by = by
        s.at = now.timeIntervalSince1970
        return s
    }

    func resumed(by: String, now: Date) -> TimerState {
        var s = self
        s.running = true
        s.endAt = now.timeIntervalSince1970 + left
        s.by = by
        s.at = now.timeIntervalSince1970
        return s
    }

    func remaining(now: Date) -> Double {
        guard running, let endAt else { return left }
        return max(0, endAt - now.timeIntervalSince1970)
    }

    // "Dumb Mode": the Tomato Focus is on only while a focus tomato is actually running.
    func focusModeOn(now: Date) -> Bool { phase == .focus && running && (endAt ?? 0) > now.timeIntervalSince1970 }

    var data: [String: Any] {
        ["phase": phase.rawValue, "tier": tier, "minutes": minutes, "running": running,
         "endAt": endAt.map { $0 as Any } ?? NSNull(), "left": left, "by": by, "at": at]
    }

    init?(data: [String: Any]) {
        guard let p = data["phase"] as? String, let phase = TimerPhase(rawValue: p) else { return nil }
        func num(_ k: String) -> Double? { (data[k] as? NSNumber)?.doubleValue }
        self.init(phase: phase, tier: data["tier"] as? String ?? "", minutes: num("minutes") ?? 0,
                  running: data["running"] as? Bool ?? false, endAt: num("endAt"), left: num("left") ?? 0,
                  by: data["by"] as? String ?? "", at: num("at") ?? 0)
    }

    init(phase: TimerPhase, tier: String, minutes: Double, running: Bool, endAt: Double?, left: Double, by: String, at: Double) {
        (self.phase, self.tier, self.minutes, self.running, self.endAt, self.left, self.by, self.at) =
            (phase, tier, minutes, running, endAt, left, by, at)
    }
}

// Same timer, ignoring who changed it and when (and sub-second clock noise).
func sameTimer(_ a: TimerState?, _ b: TimerState) -> Bool {
    guard let a else { return false }
    if a.phase == .idle && b.phase == .idle { return true }
    return a.phase == b.phase && a.tier == b.tier && a.minutes == b.minutes && a.running == b.running &&
        abs((a.endAt ?? 0) - (b.endAt ?? 0)) < 1 && (a.running || abs(a.left - b.left) < 1)
}

// A different tomato (or break) from the one shown: replace the Live Activity rather than update it.
// firebase/functions/push.js newSession is the same rule.
func isNewSession(_ prev: TimerState?, _ s: TimerState, now: Date) -> Bool {
    guard let prev else { return true }
    return prev.phase != s.phase || prev.tier != s.tier || prev.minutes != s.minutes ||
        (prev.running && (prev.endAt ?? 0) <= now.timeIntervalSince1970)
}

// Device ids travel as text; tokens as lowercase hex.
func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

// The red clock: how much of this tomato is left, 1 (full) to 0 (empty). Idle shows a full clock.
func clockFraction(_ s: TimerState, now: Date) -> Double {
    guard s.phase != .idle, s.minutes > 0 else { return 1 }
    return min(1, max(0, s.remaining(now: now) / (s.minutes * 60)))
}
