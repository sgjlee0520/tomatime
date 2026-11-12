// What the Watch app and its watch-face complication share: the timer, through the App Group.
import Foundation

func savedTimer() -> TimerState {
    appGroup.data(forKey: "timer").flatMap { try? JSONDecoder().decode(TimerState.self, from: $0) } ?? .idle(by: "", now: .distantPast)
}

func saveTimer(_ s: TimerState) { appGroup.set(try? JSONEncoder().encode(s), forKey: "timer") }
