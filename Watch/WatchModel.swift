// The watch's tomato. Actions go to the iPhone (which owns the Firebase sync); changes from the iPhone or Mac
// arrive as application context from the phone or as pushes from firebase/functions.
import UserNotifications
import WatchConnectivity
import WatchKit
import WidgetKit

@MainActor final class WatchModel: NSObject, ObservableObject {
    static let shared = WatchModel()
    @Published private(set) var state = savedTimer()
    let deviceID: String = {
        let id = appGroup.string(forKey: "deviceID") ?? "watch-" + UUID().uuidString
        appGroup.set(id, forKey: "deviceID")
        return id
    }()

    func start() {
        #if DEBUG
        // Store screenshots (tools/screenshots.sh): -demo running | clock | done
        if let demo = UserDefaults.standard.string(forKey: "demo") {
            state = .start(tier: "Red", minutes: 25, phase: .focus, by: "demo", now: .now - (demo == "done" ? 1501 : 201))
            appGroup.set(demo == "clock" ? "clock" : "numbers", forKey: "display")
            return
        }
        #endif
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        WKApplication.shared().registerForRemoteNotifications()
    }

    // MARK: Actions: shown here at once, then sent to the phone

    func start(tier i: Int) {
        appGroup.set(i, forKey: "tier")
        let t = tomatoTiers[i]
        act(.start(tier: t.name, minutes: t.minutes, phase: .focus, by: deviceID, now: .now))
    }
    func takeBreak(minutes: Double) {
        act(.start(tier: "Break", minutes: minutes, phase: .rest, by: deviceID, now: .now))
    }
    func nextTomato() { start(tier: min(appGroup.object(forKey: "tier") as? Int ?? 1, tomatoTiers.count - 1)) }
    func reset() { act(state.refilled(by: deviceID, now: .now)) }
    func pause() { act(state.paused(by: deviceID, now: .now)) }
    func resume() { act(state.resumed(by: deviceID, now: .now)) }
    func stop() { act(.idle(by: deviceID, now: .now)) }

    private func act(_ s: TimerState) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }  // first time only
        WKInterfaceDevice.current().play(isPause(from: state, to: s) ? .stop : isResume(from: state, to: s) ? .start : .click)
        apply(s)
        if let data = try? JSONEncoder().encode(s) { toPhone(["timer": data]) }
    }

    func sendToken(_ token: Data) { toPhone(["token": hex(token)]) }

    func displayChanged() {
        WidgetCenter.shared.reloadAllTimelines()
        toPhone(["display": displayStyle.rawValue])
    }

    private func toPhone(_ message: [String: Any]) {
        let m = message.merging(["watch": deviceID]) { a, _ in a }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        if session.isReachable {
            session.sendMessage(m, replyHandler: { reply in
                guard let data = reply["timer"] as? Data, let s = try? JSONDecoder().decode(TimerState.self, from: data) else { return }
                Task { @MainActor in self.applyRemote(s) }
            }, errorHandler: { _ in session.transferUserInfo(m) })
        } else {
            session.transferUserInfo(m)  // delivered when the phone is around
        }
    }

    // MARK: Changes from elsewhere

    func applyRemote(_ s: TimerState) {
        guard isNewer(s, than: state) else { return }
        if isPause(from: state, to: s) { buzzPaused() }
        apply(s)
    }

    // Paused on the iPhone or Mac: a buzz if Tomatime is on screen, otherwise a small alert (which taps the wrist).
    private func buzzPaused() {
        if WKApplication.shared().applicationState == .active { return WKInterfaceDevice.current().play(.stop) }
        let c = UNMutableNotificationContent()
        c.title = "⏸ Paused"
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "paused", content: c, trigger: nil))
    }

    private func apply(_ s: TimerState) {
        state = s
        saveTimer(s)
        WidgetCenter.shared.reloadAllTimelines()  // the watch-face complication
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["end"])
        guard s.running, let endAt = s.endAt, endAt > Date.now.timeIntervalSince1970 + 1 else { return }
        let c = UNMutableNotificationContent()
        c.title = s.phase == .rest ? "☕ Break's over" : "🍅 Tomato done!"
        c.body = s.phase == .rest ? "Ready for the next tomato?" : "Nice work. Take a break."
        c.sound = .default
        c.interruptionLevel = .timeSensitive  // gets through a Focus
        center.add(UNNotificationRequest(identifier: "end", content: c,
                                         trigger: UNTimeIntervalNotificationTrigger(timeInterval: endAt - Date.now.timeIntervalSince1970, repeats: false)))
    }
}

extension WatchModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext
        Task { @MainActor in self.context(context) }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        Task { @MainActor in self.context(context) }
    }
    private func context(_ c: [String: Any]) {
        if let d = c["display"] as? String, d != displayStyle.rawValue {
            appGroup.set(d, forKey: "display")
            WidgetCenter.shared.reloadAllTimelines()
        }
        guard let data = c["timer"] as? Data, let s = try? JSONDecoder().decode(TimerState.self, from: data) else { return }
        applyRemote(s)
    }
}
