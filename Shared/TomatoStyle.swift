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

// Shared by the iPhone app, its Live Activity, the Watch app and its complication (one App Group).
let appGroup = UserDefaults(suiteName: "group.com.sgjlee.tomatime") ?? .standard

// How the countdown looks: the numbers, or the red clock. One setting for the iPhone and the Watch.
enum DisplayStyle: String { case numbers, clock }
var displayStyle: DisplayStyle { DisplayStyle(rawValue: appGroup.string(forKey: "display") ?? "") ?? .numbers }

let clockRed = Color(red: 0.90, green: 0.20, blue: 0.15)

// A full red disc whose edge sweeps back toward 12 o'clock as the tomato runs out, white where time is gone.
struct RedClock: View {
    let fraction: Double
    var color = clockRed
    @Environment(\.isLuminanceReduced) private var dim

    var body: some View {
        GeometryReader { g in
            let w = min(g.size.width, g.size.height)
            ZStack {
                Circle().fill(Color.white.opacity(dim ? 0.2 : 1))
                Wedge(fraction: fraction).fill(color.opacity(dim ? 0.6 : 1))
                Circle().stroke(Color.black.opacity(dim ? 0.4 : 0.85), lineWidth: max(1.5, w * 0.02))
            }
            .frame(width: w, height: w)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

struct Wedge: Shape {
    var fraction: Double
    var animatableData: Double { get { fraction } set { fraction = newValue } }
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY)
        guard fraction > 0 else { return p }
        p.move(to: c)  // SwiftUI's y points down, so clockwise: false sweeps clockwise on screen
        p.addArc(center: c, radius: min(r.width, r.height) / 2, startAngle: .degrees(-90),
                 endAngle: .degrees(-90 + 360 * min(1, fraction)), clockwise: false)
        p.closeSubpath()
        return p
    }
}
