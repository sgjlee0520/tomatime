// The Live Activity (iPhone lock screen, Dynamic Island, Apple Watch Smart Stack). Its JSON is also built by
// firebase/functions/push.js contentState(): keep the field names in step. endAt is unix seconds, 0 when paused.
import ActivityKit
import Foundation

struct TomatoActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: String
        var tier: String
        var minutes: Double
        var running: Bool
        var endAt: Double
        var left: Double
    }
}

extension TomatoActivity.ContentState {
    init(_ s: TimerState) {
        self.init(phase: s.phase.rawValue, tier: s.tier, minutes: s.minutes, running: s.running,
                  endAt: s.endAt ?? 0, left: s.left)
    }
}
