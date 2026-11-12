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

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let s = model.state
            let done = s.running && (s.endAt ?? 0) <= ctx.date.timeIntervalSince1970
            if s.phase == .idle {
                List(tomatoTiers.indices, id: \.self) { i in
                    Button { model.start(tier: i) } label: {
                        HStack {
                            Circle().fill(tierColor(tomatoTiers[i].name)).frame(width: 16, height: 16)
                            Text(tomatoTiers[i].name)
                            Spacer()
                            Text("\(Int(tomatoTiers[i].minutes)) min").foregroundStyle(.secondary)
                        }
                    }
                }
                .navigationTitle("Tomatime")
            } else {
                VStack(spacing: 8) {
                    Text(done ? (s.phase == .rest ? "Break's over" : "Tomato done!")
                         : s.phase == .rest ? "Break" : "\(s.tier) tomato")
                        .font(.footnote).foregroundStyle(.secondary)
                    Countdown(running: s.running, endAt: s.endAt ?? 0, left: s.left)
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .foregroundStyle(tierColor(s.tier))
                    HStack {
                        if done {
                            if s.phase == .focus { Button("Break") { model.takeBreak() } }
                            Button("Done") { model.stop() }.tint(.red)
                        } else {
                            Button(s.running ? "Pause" : "Resume") { s.running ? model.pause() : model.resume() }.tint(.red)
                            Button("Stop") { model.stop() }
                        }
                    }
                }
            }
        }
    }
}
