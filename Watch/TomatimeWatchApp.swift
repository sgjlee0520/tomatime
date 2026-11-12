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
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    RedClock(fraction: clockFraction(s, now: ctx.date), color: s.phase == .rest ? tierColor("Break") : clockRed)
                        .padding(4)
                }
                .tag(0)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    controls(s, done: s.running && (s.endAt ?? 0) <= ctx.date.timeIntervalSince1970)
                }
                .tag(1)
                Countdown(running: s.running, endAt: s.endAt ?? 0, left: s.left)
                    .font(.system(size: 60, weight: .semibold, design: .rounded))
                    .minimumScaleFactor(0.5).lineLimit(1)
                    .foregroundStyle(tierColor(s.tier))
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
                if s.phase == .focus { Button("5 min break") { model.takeBreak() } }
                Button("Done") { model.stop() }.tint(.red)
            } else {
                Button(s.running ? "Pause" : "Resume") { s.running ? model.pause() : model.resume() }.tint(.red)
                Button("Stop") { model.stop() }
            }
        }
    }
}
