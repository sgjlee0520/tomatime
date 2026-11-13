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

    // ["watch": id] with "timer": JSON TimerState, "token": hex push token, or "display": numbers|clock
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
        // The watch sends the timer as it set it (its own clock), so a message that waited still means the same.
        if let data = m["timer"] as? Data, let s = try? JSONDecoder().decode(TimerState.self, from: data), s.by == watch {
            model.adoptFromWatch(s)
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.send(TimerModel.shared.state) }
    }
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
