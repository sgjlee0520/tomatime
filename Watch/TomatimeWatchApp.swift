// Tomatime on Apple Watch: start, pause and stop the same tomato as the iPhone and Mac.
import SwiftUI
import WatchKit

@main struct TomatimeWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchDelegate.self) var delegate
    var body: some Scene {
        WindowGroup { WatchView().environmentObject(WatchModel.shared) }
    }
}

final class WatchDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() { MainActor.assumeIsolated { WatchModel.shared.start() } }

    func didRegisterForRemoteNotifications(withDeviceToken token: Data) {
        Task { @MainActor in WatchModel.shared.sendToken(token) }
    }

    // A change made on the Mac or iPhone (firebase/functions push.js: {"timer": {...}}).
    func didReceiveRemoteNotification(_ info: [AnyHashable: Any]) async -> WKBackgroundFetchResult {
        guard let t = info["timer"] as? [String: Any], let s = TimerState(data: t) else { return .noData }
        await MainActor.run { WatchModel.shared.applyRemote(s) }
        return .newData
    }
}

struct WatchView: View {
    @EnvironmentObject var model: WatchModel
    @AppStorage("display", store: appGroup) private var style = DisplayStyle.numbers
    @State private var page = 0
    @AppStorage("restMinutes", store: appGroup) private var rest = 5.0

    var body: some View {
        let s = model.state
        if s.phase == .idle {
            List {
                ForEach(tomatoTiers.indices, id: \.self) { i in
                    Button { model.start(tier: i) } label: {
                        HStack {
                            Circle().fill(tierColor(tomatoTiers[i].name)).frame(width: 16, height: 16)
                            Text(tomatoTiers[i].name)
                            Spacer()
                            Text("\(Int(tomatoTiers[i].minutes)) min").foregroundStyle(.secondary)
                        }
                    }
                }
                Toggle("Red clock", isOn: Binding(get: { style == .clock }, set: { style = $0 ? .clock : .numbers }))
                    .onChange(of: style) { model.displayChanged() }
            }
            .navigationTitle("Tomatime")
        } else {
            // Swipe: the red clock alone | Pause/Resume + Stop | the time alone.
            TabView(selection: $page) {
                ClockPage(s: s, rest: $rest).tag(0)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    controls(s, done: s.running && (s.endAt ?? 0) <= ctx.date.timeIntervalSince1970)
                }
                .tag(1)
                Countdown(running: s.running, endAt: s.endAt ?? 0, left: s.left)
                    .font(.system(size: 60, weight: .semibold, design: .rounded))
                    .minimumScaleFactor(0.5).lineLimit(1)
                    .foregroundStyle(s.running ? tierColor(s.tier) : pausedColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onLongPressGesture(minimumDuration: 0.5) { s.running ? model.pause() : model.resume() }
                    .tag(2)
            }
            .tabViewStyle(.page)
            .onAppear { page = style == .clock ? 0 : 2 }
            .task(id: s.endAt) {  // when it runs out, show the buttons
                guard s.running, let end = s.endAt else { return }
                try? await Task.sleep(for: .seconds(max(0, end - Date.now.timeIntervalSince1970)))
                if !Task.isCancelled { page = 1 }
            }
        }
    }

    private func controls(_ s: TimerState, done: Bool) -> some View {
        VStack(spacing: 8) {
            if done {
                Text(s.phase == .rest ? "Break's over" : "Tomato done!").font(.footnote).foregroundStyle(.secondary)
                if s.phase == .focus { Button("Break · \(Int(rest)) min") { model.takeBreak(minutes: rest) } }
                Button("Done") { model.stop() }.tint(.red)
            } else {
                Button(s.running ? "Pause" : "Resume") { s.running ? model.pause() : model.resume() }.tint(.red)
                Button("Stop") { model.stop() }
            }
        }
    }
}

// Page 1. Running: the red clock; hold to pause (it goes gray, with ↺ to refill), hold again to resume.
// Tomato over: a break dial, set with the Digital Crown; hold to start the break. Break over: hold for the next tomato.
struct ClockPage: View {
    let s: TimerState
    @Binding var rest: Double
    @EnvironmentObject var model: WatchModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let done = s.running && (s.endAt ?? 0) <= ctx.date.timeIntervalSince1970
            ZStack(alignment: .bottomTrailing) {
                if done && s.phase == .focus {
                    RedClock(fraction: rest / maxRestMinutes, color: tierColor("Break"))
                        .overlay(Text("\(Int(rest)) min").font(.headline).padding(.horizontal, 6)
                            .background(.black.opacity(0.55), in: Capsule()))
                        .focusable()
                        .digitalCrownRotation($rest, from: 1, through: maxRestMinutes, by: 1, sensitivity: .low,
                                              isContinuous: false, isHapticFeedbackEnabled: true)
                        .onLongPressGesture(minimumDuration: 0.5) { model.takeBreak(minutes: rest) }
                } else {
                    RedClock(fraction: clockFraction(s, now: ctx.date),
                             color: !s.running ? pausedColor : s.phase == .rest ? tierColor("Break") : clockRed,
                             empty: s.running ? .white : pausedEmpty)
                        .onLongPressGesture(minimumDuration: 0.5) {
                            if done { model.nextTomato() } else if s.running { model.pause() } else { model.resume() }
                        }
                    if !s.running {
                        Button { model.reset() } label: { Image(systemName: "arrow.counterclockwise").font(.footnote.bold()) }
                            .buttonStyle(.borderedProminent).buttonBorderShape(.circle).tint(.gray)
                            .frame(width: 34, height: 34)
                    }
                }
            }
            .padding(4)
        }
    }
}
