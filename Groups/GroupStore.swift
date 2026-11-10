// Tomatime Groups on Firebase: configuration, sign-in, live listeners and writes.
// Data model and its security rules: firebase/firestore.rules (tested by firebase/rules.test.mjs).
import AppKit
import AuthenticationServices
import CryptoKit
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
        // Not 8080: a web filter on this Mac intercepts it. Set the host by hand: useEmulator left SSL on.
        let settings = Firestore.firestore().settings
        settings.host = "127.0.0.1:8181"
        settings.isSSLEnabled = false
        settings.cacheSettings = MemoryCacheSettings()  // every test run starts clean, like a new user
        Firestore.firestore().settings = settings
        try? Auth.auth().signOut()
        return true
    }
    guard Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else { return false }
    FirebaseApp.configure()
    return true
}

// Firestore Timestamps → Dates (recursively), so GroupRules' mappers see plain Foundation values.
private func plain(_ v: Any) -> Any {
    switch v {
    case let t as Timestamp: t.dateValue()
    case let d as [String: Any]: d.mapValues(plain)
    case let a as [Any]: a.map(plain)
    default: v
    }
}

private func isDenied(_ e: Error) -> Bool { (e as NSError).code == FirestoreErrorCode.permissionDenied.rawValue }

@MainActor final class GroupStore: NSObject {
    static let shared = GroupStore()
    private(set) var uid: String?
    private(set) var myName: String?
    private(set) var groups: [TomatoGroup] = []
    private(set) var sessions: [String: GroupSession] = [:]  // by group id
    var onChange: (() -> Void)?

    private let db = Firestore.firestore()
    private var groupsListener: ListenerRegistration?
    private var groupListeners: [String: [ListenerRegistration]] = [:]
    private var meta: [String: TomatoGroup] = [:]      // group docs, members filled in from `members`
    private var members: [String: [Member]] = [:]
    private var codes: [String: String] = [:]          // group id → invite code
    private var appleSignIn: CheckedContinuation<(AuthCredential, String?), Error>?
    private var nonce = ""

    var signedIn: Bool { uid != nil }
    func code(of gid: String) -> String? { codes[gid] }

    func start() {
        Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in self?.userChanged(user?.uid) }
        }
    }

    private func userChanged(_ newUID: String?) {
        guard newUID != uid else { return }
        stopListening()
        uid = newUID
        myName = nil
        guard let newUID else { return changed() }
        db.document("users/\(newUID)").getDocument { [weak self] snap, _ in
            Task { @MainActor in self?.myName = snap?.data()?["name"] as? String; self?.changed() }
        }
        groupsListener = db.collection("groups").whereField("memberUIDs", arrayContains: newUID)
            .addSnapshotListener(includeMetadataChanges: true) { [weak self] snap, _ in  // also: "now saved on the server"
                Task { @MainActor in self?.groupsArrived(snap?.documents ?? []) }
            }
    }

    private func stopListening() {
        groupsListener?.remove()
        groupListeners.values.joined().forEach { $0.remove() }
        groupListeners = [:]; meta = [:]; members = [:]; sessions = [:]; codes = [:]; groups = []
    }

    private func groupsArrived(_ docs: [QueryDocumentSnapshot]) {
        let ids = Set(docs.map(\.documentID))
        for gone in groupListeners.keys where !ids.contains(gone) {
            groupListeners[gone]?.forEach { $0.remove() }
            groupListeners[gone] = nil; meta[gone] = nil; members[gone] = nil; sessions[gone] = nil; codes[gone] = nil
        }
        for d in docs {
            let x = d.data()
            meta[d.documentID] = TomatoGroup(id: d.documentID, name: x["name"] as? String ?? "Group",
                                             ownerUID: x["ownerUID"] as? String ?? "",
                                             memberUIDs: x["memberUIDs"] as? [String] ?? [],
                                             unlocked: x["unlocked"] as? Bool ?? false, members: [])
            codes[d.documentID] = x["code"] as? String
            // Only once the server has the group: the rules refuse earlier listens, and a refused listener stops for good.
            if groupListeners[d.documentID] == nil, !d.metadata.hasPendingWrites { listen(to: d.documentID) }
        }
        rebuild()
    }

    private func listen(to gid: String) {
        let g = db.collection("groups").document(gid)
        groupListeners[gid] = [
            g.collection("members").addSnapshotListener { [weak self] snap, _ in
                let list = (snap?.documents ?? []).compactMap {
                    member(uid: $0.documentID, data: plain($0.data(with: .estimate)) as! [String: Any])
                }
                Task { @MainActor in self?.members[gid] = list; self?.rebuild() }
            },
            g.collection("sessions").document("current").addSnapshotListener { [weak self] snap, _ in
                let s = snap?.data(with: .estimate).flatMap { session(data: plain($0) as! [String: Any]) }
                Task { @MainActor in self?.sessions[gid] = s; self?.rebuild() }
            },
        ]
    }

    private func rebuild() {
        groups = meta.values.map { g in
            var g = g
            g.members = (members[g.id] ?? []).filter { g.memberUIDs.contains($0.uid) }.sorted { $0.joinedAt < $1.joinedAt }
            return g
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        changed()
    }

    private func changed() { onChange?() }

    // MARK: Signing in

    func signIn(anchor: NSWindow) async throws {
        if useEmulator {
            _ = try await withTimeout { try await Auth.auth().signInAnonymously() }
        } else {
            let (credential, _) = try await appleCredential(anchor: anchor)
            _ = try await withTimeout { try await Auth.auth().signIn(with: credential) }
        }
        uid = nil  // so the state listener (or this) starts the listeners
        userChanged(Auth.auth().currentUser?.uid)
    }

    // The credential, and the one-time authorization code (used to revoke the Apple token on account deletion).
    private func appleCredential(anchor: NSWindow) async throws -> (AuthCredential, String?) {
        nonce = UUID().uuidString + UUID().uuidString
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = []  // no email or name: groups use a typed display name
        request.nonce = SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        anchorWindow = anchor
        controller.presentationContextProvider = self
        return try await withCheckedThrowingContinuation { c in
            appleSignIn = c
            controller.performRequests()
        }
    }
    private var anchorWindow: NSWindow?

    func signOut() throws { try Auth.auth().signOut() }  // the state listener clears everything

    // App Store 5.1.1(v): leaves every group, deletes the display name and the account, and revokes Tomatime's
    // Sign in with Apple token. Deleting needs a recent sign-in, so it asks Apple again (that also gives the code).
    func deleteAccount(anchor: NSWindow) async throws {
        guard let user = Auth.auth().currentUser, let uid else { throw GroupError.notSignedIn }
        var appleCode: String?
        if !useEmulator {
            let (credential, code) = try await appleCredential(anchor: anchor)
            _ = try await withTimeout { try await user.reauthenticate(with: credential) }
            appleCode = code
        }
        try await online()
        for gid in groups.map(\.id) { try await leave(gid) }
        try await withTimeout { try await self.db.document("users/\(uid)").delete() }
        if let appleCode { try await withTimeout { try await Auth.auth().revokeToken(withAuthorizationCode: appleCode) } }
        try await withTimeout { try await user.delete() }
    }

    // MARK: Groups

    // The display name saved on any of my Macs (nil: never set, or offline).
    func loadName() async -> String? {
        if myName == nil, let uid {
            let snap = try? await withTimeout { try await self.db.document("users/\(uid)").getDocument() }
            myName = snap?.data()?["name"] as? String
        }
        return myName
    }

    func setName(_ name: String) async throws {
        guard let uid else { throw GroupError.notSignedIn }
        try await online()
        let batch = db.batch()
        batch.setData(["name": name], forDocument: db.document("users/\(uid)"))
        for g in groups { batch.updateData(["name": name], forDocument: memberDoc(g.id)) }
        try await withTimeout { try await batch.commit() }
        myName = name
        changed()
    }

    func createGroup(name: String, unlocked: Bool) async throws -> String {
        guard let uid, let myName else { throw GroupError.notSignedIn }
        try await online()
        for _ in 0..<3 {  // a taken code makes the batch fail; try a fresh one
            var rng = SystemRandomNumberGenerator()
            let code = makeInviteCode(using: &rng)
            let g = db.collection("groups").document()
            let batch = db.batch()
            batch.setData(["name": name, "code": code, "ownerUID": uid, "memberUIDs": [uid], "unlocked": unlocked,
                           "createdAt": FieldValue.serverTimestamp()], forDocument: g)
            batch.setData(newMember(myName, joinCode: nil), forDocument: g.collection("members").document(uid))
            batch.setData(["groupID": g.documentID], forDocument: db.document("codes/\(code)"))
            do {
                try await withTimeout { try await batch.commit() }
                return code
            } catch let error where isDenied(error) { continue }
        }
        throw GroupError.notAllowed
    }

    // Non-members can't read a group, so a refused join after a valid code means the group is full
    // (groups are free for now, so a missing pass can't be the reason).
    func join(code typed: String, hasPass: Bool) async throws -> JoinVerdict {
        guard let uid, let myName else { throw GroupError.notSignedIn }
        guard let code = normalizeCode(typed) else { throw GroupError.noSuchCode }
        try await online()
        let snap = try await withTimeout { try await self.db.document("codes/\(code)").getDocument() }
        guard let gid = snap.data()?["groupID"] as? String else { throw GroupError.noSuchCode }
        if groups.contains(where: { $0.id == gid }) { return .alreadyMember }
        let batch = db.batch()
        batch.updateData(["memberUIDs": FieldValue.arrayUnion([uid])], forDocument: db.document("groups/\(gid)"))
        var m = newMember(myName, joinCode: code)
        m["hasPass"] = hasPass
        batch.setData(m, forDocument: db.document("groups/\(gid)/members/\(uid)"))
        do {
            try await withTimeout { try await batch.commit() }
            return .ok
        } catch let error where isDenied(error) {
            return .full
        }
    }

    func leave(_ gid: String) async throws {
        guard let uid, let g = groups.first(where: { $0.id == gid }) else { throw GroupError.notSignedIn }
        try await online()
        let batch = db.batch()
        let others = g.members.filter { $0.uid != uid }
        if g.memberUIDs == [uid] {  // last one out deletes the group and its code
            batch.deleteDocument(memberDoc(gid))
            batch.deleteDocument(db.document("groups/\(gid)"))
            if let code = codes[gid] { batch.deleteDocument(db.document("codes/\(code)")) }
        } else {
            var update: [String: Any] = ["memberUIDs": FieldValue.arrayRemove([uid])]
            if g.ownerUID == uid, let heir = others.min(by: { $0.joinedAt < $1.joinedAt }) { update["ownerUID"] = heir.uid }
            batch.updateData(update, forDocument: db.document("groups/\(gid)"))
            batch.deleteDocument(memberDoc(gid))
        }
        try await withTimeout { try await batch.commit() }
    }

    func remove(_ other: String, from gid: String) async throws {
        try await online()
        let batch = db.batch()
        batch.updateData(["memberUIDs": FieldValue.arrayRemove([other])], forDocument: db.document("groups/\(gid)"))
        batch.deleteDocument(db.document("groups/\(gid)/members/\(other)"))
        try await withTimeout { try await batch.commit() }
    }

    func newCode(_ gid: String) async throws -> String {
        try await online()
        var rng = SystemRandomNumberGenerator()
        let code = makeInviteCode(using: &rng)
        let batch = db.batch()
        batch.updateData(["code": code], forDocument: db.document("groups/\(gid)"))
        batch.setData(["groupID": gid], forDocument: db.document("codes/\(code)"))
        if let old = codes[gid] { batch.deleteDocument(db.document("codes/\(old)")) }
        try await withTimeout { try await batch.commit() }
        return code
    }

    func rename(_ gid: String, to name: String) async throws {
        try await online()
        try await withTimeout { try await self.db.document("groups/\(gid)").updateData(["name": name]) }
    }

    // MARK: Live status and minutes (fire-and-forget: they catch up when back online)

    func publish(status: MemberStatus) {
        for g in groups { memberDoc(g.id).updateData(["status": statusData(status)]) }
    }

    // Only this Mac's own minutes (never the iCloud-summed tally), and only from the day you joined.
    func publishSeconds(device: String, local: [String: Double]) {
        for g in groups {
            guard let joined = g.members.first(where: { $0.uid == uid })?.joinedAt else { continue }
            memberDoc(g.id).updateData([FieldPath(["secondsByDevice", device]): secondsSince(local, joined: joined)])
        }
    }

    // MARK: Group tomatoes

    // Refused (GroupError.busy) while a group tomato or a group break is on: it would wipe it out for the others.
    func startSession(_ gid: String, tierName: String, minutes: Double) async throws {
        guard let uid else { throw GroupError.notSignedIn }
        try await online()  // the transaction alone isn't enough: disableNetwork() doesn't stop transaction calls
        let ref = sessionDoc(gid), name = myName ?? "", device = deviceKey
        try await transact { tx in
            let current = try tx.getDocument(ref).data().flatMap { session(data: plain($0) as! [String: Any]) }
            guard canStartSession(current, now: Date()) else { throw GroupError.busy }
            tx.setData(["id": UUID().uuidString, "round": 1, "startedBy": uid, "starterName": name, "tierName": tierName,
                        "minutes": minutes, "createdAt": FieldValue.serverTimestamp(), "cancelled": false,
                        "joined": [uid], "nextJoined": [], "devices": [uid: device]], forDocument: ref)
        }
    }

    // Joining also claims the tomato for this Mac: my other Macs see `devices` and stand down.
    // Only for round `sid`: a click that lands after that round was replaced or moved on changes nothing.
    func setJoined(_ gid: String, sid: String, joined: Bool) { optIn(gid, sid, "joined", joined) }
    func setNextJoined(_ gid: String, sid: String, joined: Bool) { optIn(gid, sid, "nextJoined", joined) }

    private func optIn(_ gid: String, _ sid: String, _ list: String, _ on: Bool) {
        guard let uid else { return }
        let ref = sessionDoc(gid), device = deviceKey
        Task {
            try? await transact { tx in
                guard (try tx.getDocument(ref).data()?["id"] as? String) == sid else { return }
                var d: [AnyHashable: Any] = [list: on ? FieldValue.arrayUnion([uid]) : FieldValue.arrayRemove([uid])]
                if on { d[FieldPath(["devices", uid])] = device }
                tx.updateData(d, forDocument: ref)
            }
        }
    }

    // Everyone opted in computes the same next start, so racing callers write the same thing; only the first counts.
    func advanceRound(_ gid: String, from round: Int, startAt: Date) {
        let ref = sessionDoc(gid)
        db.runTransaction({ tx, _ in
            guard let d = try? tx.getDocument(ref).data(), (d["round"] as? Int) == round else { return nil }
            tx.updateData(["round": round + 1, "startAt": startAt, "joined": d["nextJoined"] ?? [], "nextJoined": [],
                           "id": UUID().uuidString], forDocument: ref)
            return nil
        }) { _, _ in }
    }

    func cancelSession(_ gid: String, sid: String) {
        let ref = sessionDoc(gid)
        Task {
            try? await transact { tx in
                guard (try tx.getDocument(ref).data()?["id"] as? String) == sid else { return }
                tx.updateData(["cancelled": true], forDocument: ref)
            }
        }
    }

    // MARK: Helpers

    // User actions check the server first. Otherwise Firestore applies a write locally, queues it while offline
    // and sends it whenever the network is back, even after a relaunch (final review C1).
    private func online() async throws {
        guard let uid else { throw GroupError.notSignedIn }
        _ = try await withTimeout(5) { try await self.db.document("users/\(uid)").getDocument(source: .server) }
    }

    // A transaction never shows locally or queues: offline it just fails. Each attempt checks a deadline,
    // so a retry after an outage can't land long after the user gave up.
    private func transact(_ body: @escaping (Transaction) throws -> Void) async throws {
        let deadline = Date() + 8
        try await withTimeout {
            _ = try await self.db.runTransaction { tx, errorPointer in
                do {
                    guard Date() < deadline else { throw GroupError.offline }
                    try body(tx)
                } catch {
                    errorPointer?.pointee = error as NSError
                }
                return nil
            }
        }
    }

    private func memberDoc(_ gid: String) -> DocumentReference { db.document("groups/\(gid)/members/\(uid ?? "-")") }
    private func sessionDoc(_ gid: String) -> DocumentReference { db.document("groups/\(gid)/sessions/current") }

    private func newMember(_ name: String, joinCode: String?) -> [String: Any] {
        var m: [String: Any] = ["name": name, "joinedAt": FieldValue.serverTimestamp(), "hasPass": groupsFree,
                                "status": statusData(MemberStatus(state: .idle, tierName: "", minutes: 0, endsAt: nil, sessionID: nil)),
                                "secondsByDevice": [String: Any]()]
        if let joinCode { m["joinCode"] = joinCode }
        return m
    }

    // `--emulator --smoke`: sign in, name, create a group, publish a status, print the code, see Mina join, quit.
    // firebase/tools/smoke.sh
    func smoke() async -> Int32 {
        do {
            try await signIn(anchor: NSWindow())
            try await setName("Smoke")
            let code = try await createGroup(name: "Smoke Group", unlocked: true)
            for _ in 0..<50 where groups.isEmpty { try await Task.sleep(for: .milliseconds(100)) }  // listener catches up
            publish(status: MemberStatus(state: .focus, tierName: "Red", minutes: 25, endsAt: Date() + 1500, sessionID: nil))
            try await withTimeout { try await self.db.waitForPendingWrites() }
            print("SMOKE \(code)")
            fflush(stdout)
            // smoke.sh has Mina join now. The creator must see her: listeners started before the group was saved
            // were refused by the rules and stopped for good (2026-11-10).
            for _ in 0..<150 where !(groups.first?.members.contains { $0.name == "Mina" } ?? false) {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard groups.first?.members.contains(where: { $0.name == "Mina" }) == true else {
                print("SMOKE ERROR never saw Mina join")
                return 1
            }
            print("SMOKE SAW Mina")
            // Offline, "Start group tomato" fails and starts nothing, then or later (final review C1).
            guard let gid = groups.first?.id else { return 1 }
            try await db.disableNetwork()
            let started = (try? await startSession(gid, tierName: "Red", minutes: 25)) != nil
            let shown = sessions[gid] != nil
            try await db.enableNetwork()
            try await Task.sleep(for: .seconds(3))
            let saved = try await withTimeout { try await self.sessionDoc(gid).getDocument(source: .server) }.exists
            guard !started, !shown, !saved else {
                print("SMOKE ERROR offline start: returned \(started), shown \(shown), saved later \(saved)")
                return 1
            }
            print("SMOKE offline start refused")
            // Online it starts; a second start while it's on is refused, not an overwrite (final review I1).
            try await startSession(gid, tierName: "Red", minutes: 25)
            if (try? await startSession(gid, tierName: "Green", minutes: 20)) != nil {
                print("SMOKE ERROR a second start replaced the first")
                return 1
            }
            print("SMOKE second start refused")
            // A click meant for a round that's gone changes nothing (final review I1).
            setNextJoined(gid, sid: "an-old-round", joined: true)
            try await Task.sleep(for: .seconds(2))
            let next = try await withTimeout { try await self.sessionDoc(gid).getDocument(source: .server) }.data()?["nextJoined"]
            guard (next as? [String])?.isEmpty == true else { print("SMOKE ERROR a stale opt-in landed: \(String(describing: next))"); return 1 }
            print("SMOKE stale opt-in ignored")
            // Deleting the account leaves the group (Mina becomes the owner), removes the name and the sign-in (I4).
            let me = uid ?? ""
            try await deleteAccount(anchor: NSWindow())
            print("SMOKE DELETED \(me) \(gid)")
            return 0
        } catch {
            print("SMOKE ERROR \(error.localizedDescription)")
            return 1
        }
    }
}

extension GroupStore: ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    nonisolated func authorizationController(controller: ASAuthorizationController,
                                             didCompleteWithAuthorization authorization: ASAuthorization) {
        Task { @MainActor in
            guard let apple = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let token = apple.identityToken.flatMap({ String(data: $0, encoding: .utf8) }) else {
                appleSignIn?.resume(throwing: GroupError.notSignedIn); appleSignIn = nil; return
            }
            appleSignIn?.resume(returning: (OAuthProvider.appleCredential(withIDToken: token, rawNonce: nonce,
                                                                          fullName: apple.fullName),
                                            apple.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }))
            appleSignIn = nil
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        Task { @MainActor in appleSignIn?.resume(throwing: error); appleSignIn = nil }
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated { anchorWindow ?? NSApp.windows.first ?? NSWindow() }
    }
}
