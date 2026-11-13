// Tomatime for iPhone: the same tomatoes as the Mac menu-bar timer, plus the lock screen and the watch.
import FirebaseCore
import SwiftUI
import UserNotifications

@main struct TomatimeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup { ContentView().environmentObject(TimerModel.shared) }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ app: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil { FirebaseApp.configure() }
        UNUserNotificationCenter.current().delegate = self
        MainActor.assumeIsolated { TimerModel.shared.start() }
        return true
    }

    func application(_: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        Task { @MainActor in TimerModel.shared.saveToken("apns", hex(token)) }
    }

    // A change made on the Mac or watch (firebase/functions push.js: {"timer": {...}}).
    func application(_: UIApplication, didReceiveRemoteNotification info: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard let t = info["timer"] as? [String: Any], let s = TimerState(data: t) else { return .noData }
        await MainActor.run { TimerModel.shared.applyRemote(s) }
        return .newData
    }

    func userNotificationCenter(_: UNUserNotificationCenter, willPresent _: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
