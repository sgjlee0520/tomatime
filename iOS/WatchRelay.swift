// The watch has no Firebase (no gRPC on watchOS): it talks to the shared timer through this phone.
// Phone → watch: the current timer (application context). Watch → phone: actions and its push token.
import WatchConnectivity

final class WatchRelay: NSObject, WCSessionDelegate {
    static let shared = WatchRelay()

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(_ s: TimerState) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated, WCSession.default.isPaired,
              let data = try? JSONEncoder().encode(s) else { return }
        try? WCSession.default.updateApplicationContext(["timer": data, "display": displayStyle.rawValue])
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in
            handle(message)
            replyHandler(["timer": (try? JSONEncoder().encode(TimerModel.shared.state)) ?? Data()])
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in handle(userInfo) }
    }

    // ["action": start|break|pause|resume|stop|state, "watch": id, "tier": index] or ["token": hex, "watch": id]
    @MainActor private func handle(_ m: [String: Any]) {
        let model = TimerModel.shared
        guard let watch = m["watch"] as? String else { return }
        if let d = m["display"] as? String, d != displayStyle.rawValue {
            appGroup.set(d, forKey: "display")
            model.displayChanged()
        }
        if let token = m["token"] as? String {
            model.saveDevice(["apns": token], id: watch, platform: "watchos")
        }
        switch m["action"] as? String {
        case "start":
            if let i = m["tier"] as? Int, tomatoTiers.indices.contains(i) { model.tierIndex = i }
            model.startTomato(by: watch)
        case "break": model.startBreak(by: watch)
        case "pause": model.pause(by: watch)
        case "resume": model.resume(by: watch)
        case "stop": model.stop(by: watch)
        default: break
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.send(TimerModel.shared.state) }
    }
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
