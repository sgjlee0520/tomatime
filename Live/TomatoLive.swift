// Lock screen, Dynamic Island and (watchOS 11+, family .small) the Apple Watch Smart Stack.
import ActivityKit
import SwiftUI
import WidgetKit

@main struct LiveBundle: WidgetBundle {
    var body: some Widget { TomatoLive() }
}

struct TomatoLive: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TomatoActivity.self) { ctx in
            Banner(s: ctx.state)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { ctx in
            let s = ctx.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image("Tomato").resizable().scaledToFit().frame(width: 36) }
                DynamicIslandExpandedRegion(.center) { Text(title(s)).font(.headline) }
                DynamicIslandExpandedRegion(.trailing) {
                    Countdown(running: s.running, endAt: s.endAt, left: s.left).font(.title2.bold())
                        .foregroundStyle(tierColor(s.tier))
                }
            } compactLeading: {
                Image("Tomato").resizable().scaledToFit().frame(width: 20)
            } compactTrailing: {
                Countdown(running: s.running, endAt: s.endAt, left: s.left).frame(width: 52)
                    .foregroundStyle(tierColor(s.tier))
            } minimal: {
                Image("Tomato").resizable().scaledToFit().frame(width: 20)
            }
        }
        .supplementalActivityFamilies([.small])
    }
}

private func title(_ s: TomatoActivity.ContentState) -> String {
    let what = s.phase == "break" ? "☕ Break" : "\(s.tier) tomato"
    return s.running ? what : "\(what) · paused"
}

struct Banner: View {
    let s: TomatoActivity.ContentState
    @Environment(\.activityFamily) private var family
    @Environment(\.isLuminanceReduced) private var dim

    var body: some View {
        if family == .small {  // Apple Watch: big countdown, dimmer in Always On
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image("Tomato").resizable().scaledToFit().frame(width: 18)
                    Text(title(s)).font(.caption).lineLimit(1)
                }
                Countdown(running: s.running, endAt: s.endAt, left: s.left)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(dim ? .white.opacity(0.7) : tierColor(s.tier))
            }
            .padding(8)
        } else {
            HStack(spacing: 14) {
                Image("Tomato").resizable().scaledToFit().frame(width: 48)
                VStack(alignment: .leading) {
                    Text(title(s)).font(.headline).foregroundStyle(.white)
                    Text(s.phase == "break" ? "Rest a little" : "Stay with it").font(.subheadline).foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                Countdown(running: s.running, endAt: s.endAt, left: s.left)
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .foregroundStyle(tierColor(s.tier))
            }
            .padding()
        }
    }
}
