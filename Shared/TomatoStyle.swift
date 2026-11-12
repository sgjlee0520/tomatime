// Colors and countdown text shared by the iPhone app, its Live Activity and the Watch.
import SwiftUI

func tierColor(_ name: String) -> Color {
    switch name {
    case "Green": Color(red: 0.45, green: 0.78, blue: 0.25)
    case "Golden": Color(red: 1.00, green: 0.76, blue: 0.10)
    case "Diamond": Color(red: 0.55, green: 0.88, blue: 1.00)
    case "Break": Color(red: 0.55, green: 0.62, blue: 0.70)
    default: Color(red: 0.90, green: 0.20, blue: 0.15)
    }
}

func clock(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded(.up)))
    return String(format: "%d:%02d", s / 60, s % 60)
}

// Ticks by itself (also on the lock screen and in Always On) while running; a still time while paused.
struct Countdown: View {
    let running: Bool
    let endAt: Double
    let left: Double
    var body: some View {
        let end = Date(timeIntervalSince1970: endAt)
        if running, end > .now {
            Text(timerInterval: Date.now...end, countsDown: true).monospacedDigit()
        } else if running {
            Text("Done")
        } else {
            Text(clock(left)).monospacedDigit()
        }
    }
}
