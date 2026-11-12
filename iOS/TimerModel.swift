// The iPhone's tomato timer. Works alone; signed in, it follows and updates the shared timer that the Mac and
// Watch use (Shared/TomatoTimer.swift). Pushes from firebase/functions bring changes made elsewhere.
import ActivityKit
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import UIKit
import UserNotifications

@MainActor final class TimerModel: ObservableObject {
    static let shared = TimerModel()

    @Published private(set) var state: TimerState
    @Published var tierIndex: Int { didSet { UserDefaults.standard.set(tierIndex, forKey: "tier") } }
    @Published private(set) var uid: String?

    let deviceID: String
    private var db: Firestore? { FirebaseApp.app() == nil ? nil : Firestore.firestore() }
    private var listener: ListenerRegistration?
    private var activityTokens: [String: String] = [:]  // Live Activity id → its push token

    private init() {
        let d = UserDefaults.standard
        deviceID = d.string(forKey: "deviceID") ?? "ios-" + UUID().uuidString
        d.set(deviceID, forKey: "deviceID")
        state = (d.data(forKey: "timer").flatMap { try? JSONDecoder().decode(TimerState.self, from: $0) })
            ?? .idle(by: "", now: .now)
        tierIndex = min(d.object(forKey: "tier") as? Int ?? 1, tomatoTiers.count - 1)
    }

    func start() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        WatchRelay.shared.start()
        watchActivities()
        guard FirebaseApp.app() != nil else { return }
        Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in self?.userChanged(user?.uid) }
        }
    }

    // MARK: Actions on this phone (or on the watch, with its id)

    func startTomato(by: String? = nil) {
        let t = tomatoTiers[tierIndex]
        change(.start(tier: t.name, minutes: t.minutes, phase: .focus, by: by ?? deviceID, now: .now))
    }
    func startBreak(minutes: Double = 5, by: String? = nil) {
        change(.start(tier: "Break", minutes: minutes, phase: .rest, by: by ?? deviceID, now: .now))
    }
    func pause(by: String? = nil) { if state.running { change(state.paused(by: by ?? deviceID, now: .now)) } }
    func resume(by: String? = nil) { if !state.running, state.phase != .idle { change(state.resumed(by: by ?? deviceID, now: .now)) } }
    func stop(by: String? = nil) { change(.idle(by: by ?? deviceID, now: .now)) }

    private func change(_ s: TimerState) {
        let prev = state
        apply(s)
        if s.by == deviceID { Task { await showLiveActivity(s, prev: prev) } }  // the watch's: the server starts it
        guard let uid, let db else { return }
        let bg = UIApplication.shared.beginBackgroundTask()  // a watch action may have woken us in the background
        db.document("users/\(uid)/timer/current").setData(s.data) { _ in UIApplication.shared.endBackgroundTask(bg) }
    }

    // MARK: Changes from the Mac or watch

    func applyRemote(_ s: TimerState) {
        // Pushes can arrive late: never go back to an older change.
        guard s.by != deviceID, s.at >= state.at, !sameTimer(state, s) else { return }
        apply(s)
    }

    private func apply(_ s: TimerState) {
        state = s
        UserDefaults.standard.set(try? JSONEncoder().encode(s), forKey: "timer")
        if let i = tomatoTiers.firstIndex(where: { $0.name == s.tier }) { tierIndex = i }
        scheduleEndNotification(s)
        WatchRelay.shared.send(s)
    }

    private func scheduleEndNotification(_ s: TimerState) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["end"])
        guard s.running, let endAt = s.endAt, endAt > Date.now.timeIntervalSince1970 + 1 else { return }
        let c = UNMutableNotificationContent()
        c.title = s.phase == .rest ? "☕ Break's over" : "🍅 Tomato done!"
        c.body = s.phase == .rest ? "Ready for the next tomato?" : "Nice work. Take a break."
        c.sound = .default
        c.interruptionLevel = .timeSensitive
        center.add(UNNotificationRequest(identifier: "end", content: c,
                                         trigger: UNTimeIntervalNotificationTrigger(timeInterval: endAt - Date.now.timeIntervalSince1970, repeats: false)))
    }

    // MARK: Live Activity (this phone's own actions; the rest arrive as pushes)

    private func showLiveActivity(_ s: TimerState, prev: TimerState) async {
        let current = Activity<TomatoActivity>.activities
        let content = ActivityContent(state: TomatoActivity.ContentState(s),
                                      staleDate: s.running ? s.endAt.map { Date(timeIntervalSince1970: $0) } : nil)
        if s.phase != .idle, let a = current.first, !isNewSession(prev, s, now: .now) {
            await a.update(content)
            return
        }
        for a in current { await a.end(nil, dismissalPolicy: .immediate) }
        guard s.phase != .idle else { return }
        _ = try? Activity.request(attributes: TomatoActivity(), content: content, pushType: .token)
    }

    // Tokens the server needs: one to start a Live Activity, one per running Live Activity to update/end it.
    private func watchActivities() {
        Task {
            for await t in Activity<TomatoActivity>.pushToStartTokenUpdates { saveDevice(["pushToStart": hex(t)]) }
        }
        Task {
            for a in Activity<TomatoActivity>.activities { follow(a) }
            for await a in Activity<TomatoActivity>.activityUpdates { follow(a) }
        }
    }

    private func follow(_ a: Activity<TomatoActivity>) {
        Task {
            for await t in a.pushTokenUpdates {
                activityTokens[a.id] = hex(t)
                saveDevice(["activity": hex(t)])
            }
        }
        Task {
            for await st in a.activityStateUpdates where st == .ended || st == .dismissed {
                if let t = activityTokens.removeValue(forKey: a.id) { clearActivityToken(t) }
            }
        }
    }

    // MARK: Account and device

    private func userChanged(_ newUID: String?) {
        guard newUID != uid else { return }
        listener?.remove()
        uid = newUID
        guard let newUID, let db else { return }
        saveDevice(["platform": "ios"])
        UIApplication.shared.registerForRemoteNotifications()
        listener = db.document("users/\(newUID)/timer/current").addSnapshotListener { [weak self] snap, _ in
            guard let snap, !snap.metadata.hasPendingWrites, let s = snap.data().flatMap(TimerState.init(data:)) else { return }
            Task { @MainActor in self?.applyRemote(s) }
        }
    }

    func saveDevice(_ fields: [String: Any], id: String? = nil, platform: String = "ios") {
        guard let uid, let db else { return }
        #if DEBUG
        let env = "development"
        #else
        let env = "production"
        #endif
        db.document("users/\(uid)/devices/\(id ?? deviceID)")
            .setData(fields.merging(["platform": platform, "env": env, "at": Date.now.timeIntervalSince1970]) { a, _ in a }, merge: true)
    }

    // A finished Live Activity's token is spent; forget it unless a newer one is already saved.
    private func clearActivityToken(_ token: String) {
        guard let uid, let db else { return }
        let ref = db.document("users/\(uid)/devices/\(deviceID)")
        db.runTransaction({ tx, _ in
            if (try? tx.getDocument(ref))?.data()?["activity"] as? String == token {
                tx.updateData(["activity": FieldValue.delete()], forDocument: ref)
            }
            return nil
        }) { _, _ in }
    }

    func signOut() { try? Auth.auth().signOut() }

    // Numbers or red clock changed (here or on the watch): tell the watch, redraw the lock screen.
    func displayChanged() {
        WatchRelay.shared.send(state)
        Task { for a in Activity<TomatoActivity>.activities { await a.update(a.content) } }
    }
}
