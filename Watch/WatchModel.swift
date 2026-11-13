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
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
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
        act(.start(tier: t.name, minutes: t.minutes, phase: .focus, by: deviceID, now: .now), ["action": "start", "tier": i])
    }
    func takeBreak(minutes: Double) {
        act(.start(tier: "Break", minutes: minutes, phase: .rest, by: deviceID, now: .now), ["action": "break", "minutes": minutes])
    }
    func nextTomato() { start(tier: min(appGroup.object(forKey: "tier") as? Int ?? 1, tomatoTiers.count - 1)) }
    func reset() { act(state.refilled(by: deviceID, now: .now), ["action": "reset"]) }
    func pause() { act(state.paused(by: deviceID, now: .now), ["action": "pause"]) }
    func resume() { act(state.resumed(by: deviceID, now: .now), ["action": "resume"]) }
    func stop() { act(.idle(by: deviceID, now: .now), ["action": "stop"]) }

    private func act(_ s: TimerState, _ message: [String: Any]) {
        WKInterfaceDevice.current().play(.click)
        apply(s)
        toPhone(message)
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
        guard s.at >= state.at, !sameTimer(state, s) else { return }  // never go back to an older change
        apply(s)
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
