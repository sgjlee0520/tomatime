// What the Watch app and its watch-face complication share: the timer, through the App Group.
import Foundation

let watchGroup = UserDefaults(suiteName: "group.com.sgjlee.tomatime") ?? .standard

func savedTimer() -> TimerState {
    watchGroup.data(forKey: "timer").flatMap { try? JSONDecoder().decode(TimerState.self, from: $0) } ?? .idle(by: "", now: .distantPast)
}

func saveTimer(_ s: TimerState) { watchGroup.set(try? JSONEncoder().encode(s), forKey: "timer") }
