// Tomatime Groups on Firebase: configuration, sign-in, live listeners and writes.
import AppKit
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore

let useEmulator = CommandLine.arguments.contains("--emulator")  // local Firebase emulators (firebase/firebase.json)

// Groups exist only when Firebase is configured: the bundled GoogleService-Info.plist, or the local emulators.
// Without either, Tomatime is the solo timer it always was.
func configureFirebase() -> Bool {
    if useEmulator {
        let o = FirebaseOptions(googleAppID: "1:1:ios:1", gcmSenderID: "1")
        o.projectID = "demo-tomatime"
        o.apiKey = "AIzaFakeKeyForTheLocalEmulator00000000"
        FirebaseApp.configure(options: o)
        Auth.auth().useEmulator(withHost: "127.0.0.1", port: 9099)
        Firestore.firestore().useEmulator(withHost: "127.0.0.1", port: 8181)  // not 8080: a web filter intercepts it
        return true
    }
    guard Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else { return false }
    FirebaseApp.configure()
    return true
}
