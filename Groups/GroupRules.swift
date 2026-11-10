// Group tomato rules: plain values and decisions, no Firebase or AppKit, so tools/test.sh can check them.
import Foundation

let maxGroupSize = 6, countdownSeconds = 10, groupBreakMinutes = 10.0, activeMacSeconds = 120.0
let groupsFree = true   // until the Paid Apps agreement is active; then passes (StoreKit) unlock groups

// Local calendar day, e.g. "2026-11-9". Used for the solo tally, iCloud sync and group minutes.
func dayKey(_ date: Date = Date()) -> String {
    let d = Calendar.current.dateComponents([.year, .month, .day], from: date)
    return "\(d.year!)-\(d.month!)-\(d.day!)"
}

enum MemberState: String { case focus, rest = "break", idle }

struct MemberStatus: Equatable {
    var state: MemberState
    var tierName: String
    var minutes: Double
    var endsAt: Date?
    var sessionID: String?
}

struct Member {
    let uid: String
    var name: String
    var joinedAt: Date
    var hasPass: Bool
    var status: MemberStatus
    var secondsByDevice: [String: [String: Double]]  // device → dayKey → seconds
}

struct TomatoGroup {
    let id: String
    var name: String
    var ownerUID: String
    var memberUIDs: [String]
    var unlocked: Bool
    var members: [Member]
}

struct GroupSession {
    let id: String
    var round: Int
    var startedBy: String
    var starterName: String
    var tierName: String
    var minutes: Double
    var startAt: Date
    var cancelled: Bool
    var joined: [String]
    var nextJoined: [String]
}

enum JoinVerdict: Equatable { case ok, alreadyMember, full, needsPass }
enum SessionPhase: Equatable { case countdown(Int), running(Double), over }  // seconds to start / seconds left

func joinVerdict(_ g: TomatoGroup, uid: String, hasPass: Bool) -> JoinVerdict {
    if g.memberUIDs.contains(uid) { return .alreadyMember }
    if g.memberUIDs.count >= maxGroupSize { return .full }
    return g.unlocked || hasPass ? .ok : .needsPass
}

func effectiveState(_ s: MemberStatus, now: Date) -> MemberState {
    if s.state != .idle, let end = s.endsAt, end <= now { return .idle }
    return s.state
}

func friendsFocusing(_ groups: [TomatoGroup], me: String, now: Date) -> Int {
    Set(groups.flatMap(\.members).filter { $0.uid != me && effectiveState($0.status, now: now) == .focus }.map(\.uid)).count
}

func statusText(_ m: Member, now: Date) -> String {
    let left = Int(((m.status.endsAt ?? now).timeIntervalSince(now) / 60).rounded(.up))
    switch effectiveState(m.status, now: now) {
    case .focus: return "\(m.status.tierName) · \(left) min"
    case .rest: return "break · \(left) min"
    case .idle: return "\(Int(memberSeconds(m, day: now) / 60)) min today"
    }
}

func memberSeconds(_ m: Member, day: Date) -> Double {
    if Calendar.current.startOfDay(for: day) < Calendar.current.startOfDay(for: m.joinedAt) { return 0 }
    let key = dayKey(day)
    return m.secondsByDevice.values.reduce(0) { $0 + ($1[key] ?? 0) }
}

func groupDayMinutes(_ g: TomatoGroup, days: [Date]) -> [Int] {
    days.map { day in Int((g.members.reduce(0) { $0 + memberSeconds($1, day: day) } + 30) / 60) }
}

func weeklyRanking(_ g: TomatoGroup, now: Date, calendar: Calendar) -> [(name: String, minutes: Int)] {
    let start = calendar.dateInterval(of: .weekOfYear, for: now)!.start
    let days = (0..<7).map { calendar.date(byAdding: .day, value: $0, to: start)! }
    return g.members
        .map { m in (name: m.name, minutes: Int((days.reduce(0) { $0 + memberSeconds(m, day: $1) } + 30) / 60)) }
        .sorted { $0.minutes != $1.minutes ? $0.minutes > $1.minutes : $0.name < $1.name }
}

func sessionPhase(_ s: GroupSession, now: Date) -> SessionPhase {
    if s.cancelled { return .over }
    let toStart = s.startAt.timeIntervalSince(now)
    if toStart > 0 { return .countdown(Int(toStart.rounded(.up))) }
    let left = s.minutes * 60 + toStart
    return left > 0 ? .running(left) : .over
}

func nextRoundStart(after end: Date) -> Date { end + groupBreakMinutes * 60 }

func shouldAutoJoin(idleSeconds: Double) -> Bool { idleSeconds < activeMacSeconds }

private let codeAlphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")  // no 0/O, 1/I: easy to type

func makeInviteCode<R: RandomNumberGenerator>(using rng: inout R) -> String {
    "TOMA-" + String((0..<6).map { _ in codeAlphabet.randomElement(using: &rng)! })
}

func normalizeCode(_ s: String) -> String? {
    var c = s.uppercased().filter { !$0.isWhitespace }
    if c.hasPrefix("TOMA-") { c.removeFirst(5) }
    guard c.count == 6, c.allSatisfy(codeAlphabet.contains) else { return nil }
    return "TOMA-" + c
}

// Firestore boundary. GroupStore converts Timestamps to Dates before calling these.

func statusData(_ s: MemberStatus) -> [String: Any] {
    var d: [String: Any] = ["state": s.state.rawValue, "tierName": s.tierName, "minutes": s.minutes]
    d["endsAt"] = s.endsAt ?? NSNull()
    d["sessionID"] = s.sessionID ?? NSNull()
    return d
}

func member(uid: String, data: [String: Any]) -> Member? {
    guard let name = data["name"] as? String, let joinedAt = data["joinedAt"] as? Date else { return nil }
    let st = data["status"] as? [String: Any] ?? [:]
    let status = MemberStatus(state: MemberState(rawValue: st["state"] as? String ?? "") ?? .idle,
                              tierName: st["tierName"] as? String ?? "",
                              minutes: (st["minutes"] as? NSNumber)?.doubleValue ?? 0,
                              endsAt: st["endsAt"] as? Date, sessionID: st["sessionID"] as? String)
    let secs = (data["secondsByDevice"] as? [String: [String: Any]] ?? [:])
        .mapValues { $0.compactMapValues { ($0 as? NSNumber)?.doubleValue } }
    return Member(uid: uid, name: name, joinedAt: joinedAt, hasPass: data["hasPass"] as? Bool ?? false,
                  status: status, secondsByDevice: secs)
}

// Round 1 stores only the server's createdAt (start = 10 s later); later rounds store startAt.
func session(id: String, data: [String: Any]) -> GroupSession? {
    guard let startedBy = data["startedBy"] as? String,
          let startAt = data["startAt"] as? Date ?? (data["createdAt"] as? Date).map({ $0 + Double(countdownSeconds) })
    else { return nil }
    return GroupSession(id: id, round: (data["round"] as? NSNumber)?.intValue ?? 1, startedBy: startedBy,
                        starterName: data["starterName"] as? String ?? "", tierName: data["tierName"] as? String ?? "",
                        minutes: (data["minutes"] as? NSNumber)?.doubleValue ?? 0, startAt: startAt,
                        cancelled: data["cancelled"] as? Bool ?? false, joined: data["joined"] as? [String] ?? [],
                        nextJoined: data["nextJoined"] as? [String] ?? [])
}

enum GroupError: LocalizedError {
    case offline, notSignedIn, noSuchCode, full, notAllowed
    var errorDescription: String? {
        switch self {
        case .offline: "Couldn't reach Tomatime Groups. Check your connection."
        case .notSignedIn: "Sign in with Apple first."
        case .noSuchCode: "No group has that invite code. Check it and try again."
        case .full: "This group is full (6 people)."
        case .notAllowed: "You can't do that in this group."
        }
    }
}

// Firestore waits forever while offline; user actions give up after 10 s instead.
// Not a task group: a group waits for every child, and Firestore's waits ignore cancellation.
func withTimeout<T>(_ seconds: Double = 10, _ work: @escaping () async throws -> T) async throws -> T {
    let lock = NSLock()
    var done = false
    func once(_ f: () -> Void) { lock.lock(); defer { lock.unlock() }; if !done { done = true; f() } }
    return try await withCheckedThrowingContinuation { c in
        Task {
            do { let v = try await work(); once { c.resume(returning: v) } } catch { once { c.resume(throwing: error) } }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            once { c.resume(throwing: GroupError.offline) }
        }
    }
}
