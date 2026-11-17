// Group tomato rules: plain values and decisions, no Firebase or AppKit, so tools/test.sh can check them.
import Foundation

let maxGroupSize = 6, countdownSeconds = 10, groupBreakMinutes = 10.0, activeMacSeconds = 120.0
let groupsFree = true   // until the Paid Apps agreement is active; then passes (StoreKit) unlock groups

// Day keys and group days are Gregorian on every Mac (Thai Macs default to the Buddhist calendar), in local time.
let gregorian: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = .autoupdatingCurrent
    return c
}()

// Local calendar day, e.g. "2026-11-9". Used for the solo tally, iCloud sync and group minutes.
func dayKey(_ date: Date = Date()) -> String {
    let d = gregorian.dateComponents([.year, .month, .day], from: date)
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
    var devices: [String: String]  // member → the one Mac of theirs that runs this tomato (last to opt in)
    var plan: [Double] = []          // Exam mode: focus, break, focus, …, focus minutes; round r runs plan[2(r-1)]
    var nextTierName: String? = nil  // the tomato someone picked for round `nextRound`, during the group break
    var nextMinutes: Double? = nil
    var nextRound: Int? = nil
}

enum JoinVerdict: Equatable { case ok, alreadyMember, full, needsPass }
enum CountdownMode { case invite, autoJoin, starter }
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

// Minutes shown anywhere: whole minutes done. A finished tomato tallies a few ms short of its length, so half a
// second is forgiven. One rule for a person's line, the calendar squares and the ranking, so they agree.
func wholeMinutes(_ seconds: Double) -> Int { Int((seconds + 0.5) / 60) }

func statusText(_ m: Member, now: Date) -> String {
    let left = Int(((m.status.endsAt ?? now).timeIntervalSince(now) / 60).rounded(.up))
    switch effectiveState(m.status, now: now) {
    case .focus: return "\(m.status.tierName) · \(left) min"
    case .rest: return "break · \(left) min"
    case .idle: return "\(wholeMinutes(memberSeconds(m, day: now))) min today"
    }
}

func memberSeconds(_ m: Member, day: Date) -> Double {
    if Calendar.current.startOfDay(for: day) < Calendar.current.startOfDay(for: m.joinedAt) { return 0 }
    let key = dayKey(day)
    return m.secondsByDevice.values.reduce(0) { $0 + ($1[key] ?? 0) }
}

func groupDayMinutes(_ g: TomatoGroup, days: [Date]) -> [Int] {
    days.map { day in g.members.reduce(0) { $0 + wholeMinutes(memberSeconds($1, day: day)) } }
}

// One day's minutes per member, most first (ties alphabetical): the calendar shows them when a day is clicked.
func dayRanking(_ g: TomatoGroup, day: Date) -> [(name: String, minutes: Int)] {
    g.members.map { (name: $0.name, minutes: wholeMinutes(memberSeconds($0, day: day))) }
        .sorted { $0.minutes != $1.minutes ? $0.minutes > $1.minutes : $0.name < $1.name }
}

func weeklyRanking(_ g: TomatoGroup, now: Date, calendar: Calendar) -> [(name: String, minutes: Int)] {
    let start = calendar.dateInterval(of: .weekOfYear, for: now)!.start
    let days = (0..<7).map { calendar.date(byAdding: .day, value: $0, to: start)! }
    return g.members
        .map { m in (name: m.name, minutes: days.reduce(0) { $0 + wholeMinutes(memberSeconds(m, day: $1)) }) }
        .sorted { $0.minutes != $1.minutes ? $0.minutes > $1.minutes : $0.name < $1.name }
}

func sessionPhase(_ s: GroupSession, now: Date) -> SessionPhase {
    if s.cancelled { return .over }
    let toStart = s.startAt.timeIntervalSince(now)
    if toStart > 0 { return .countdown(Int(toStart.rounded(.up))) }
    let left = s.minutes * 60 + toStart
    return left > 0 ? .running(left) : .over
}

// Exam mode: a plan of tomatoes and breaks run back to back, solo or as a group; people can type their own.
// The recommended one and the studies behind it: docs/exam-mode-science.md. In short: a short opener, the longest
// tomato second (while fresh, not last), breaks that grow, one of 20 minutes, no phone in breaks, a walk at the end.
let recommendedExamPlan: [Double] = [25, 8, 60, 10, 45, 20, 45]
let examDoneText = "Go take a walk."
func examBreakText(_ minutes: Double) -> String {
    minutes >= 15 ? "Leave your desk and walk, outside if you can. Phone stays in your pocket."
                  : "Stand up, stretch, drink some water. Leave your phone alone."
}

// "25, 8, 45, 10, 45" → focus, break, focus, break, focus. Starts and ends with a tomato; whole minutes, 1 to 480.
func parseExamPlan(_ text: String) -> [Double]? {
    let parts = text.split(whereSeparator: { !$0.isNumber })
    let plan = parts.compactMap { Double($0) }
    guard plan.count == parts.count, plan.count >= 3, plan.count <= 23, plan.count % 2 == 1,
          plan.allSatisfy({ $0 >= 1 && $0 <= 480 }) else { return nil }
    return plan
}
func examTomatoes(_ plan: [Double]) -> [Double] { stride(from: 0, to: plan.count, by: 2).map { plan[$0] } }
// "25 → 45 → 45 → 60 min"
func examText(_ plan: [Double]) -> String { examTomatoes(plan).map { "\(Int($0))" }.joined(separator: " → ") + " min" }

// A tomato's name from its length: one of the four, or "50-min".
func tomatoName(_ minutes: Double) -> String { tomatoTiers.first { $0.minutes == minutes }?.name ?? "\(Int(minutes))-min" }

// The break after this round: 10 minutes, or what the Exam mode plan says. nil: its last tomato (no next round).
func breakAfter(_ s: GroupSession) -> Double? {
    if s.plan.isEmpty { return groupBreakMinutes }
    let i = 2 * s.round - 1
    return i + 1 < s.plan.count ? s.plan[i] : nil
}
func nextRoundStart(_ s: GroupSession) -> Date? { breakAfter(s).map { s.startAt + (s.minutes + $0) * 60 } }

// The tomato someone picked for round `round` (a pick names its round, so one made a moment early or late
// can't be taken for another round's).
func picked(_ s: GroupSession, for round: Int) -> (name: String, minutes: Double)? {
    guard s.plan.isEmpty, let m = s.nextMinutes, s.nextRound == round else { return nil }
    return (s.nextTierName ?? tomatoName(m), m)
}

// The next round's tomato: the plan's, or what someone picked during the group break, or the same again.
func nextTomato(_ s: GroupSession) -> (name: String, minutes: Double) {
    if !s.plan.isEmpty {
        let m = 2 * s.round < s.plan.count ? s.plan[2 * s.round] : s.minutes
        return (tomatoName(m), m)
    }
    return picked(s, for: s.round + 1) ?? (s.tierName, s.minutes)
}

// Tomatime 1.2.2 and older move the group on with the same tomato again: they don't know the pick or the plan.
// What this round should be instead (nil: it's right); a newer Tomatime puts it right as the countdown shows.
func roundFix(_ s: GroupSession) -> (name: String, minutes: Double)? {
    guard s.round > 1 else { return nil }
    if s.plan.isEmpty { return picked(s, for: s.round) }
    let i = 2 * (s.round - 1)
    return i < s.plan.count && s.plan[i] != s.minutes ? (tomatoName(s.plan[i]), s.plan[i]) : nil
}

// A running group tomato can be made longer or shorter by anyone in it, as long as a minute of it is left.
// Not in its last 10 seconds: the others' may already have run out before the change reaches them.
func canResize(_ s: GroupSession, to minutes: Double, now: Date) -> Bool {
    guard s.plan.isEmpty, case .running(let left) = sessionPhase(s, now: now), left > 10 else { return false }
    return s.startAt + minutes * 60 > now + 60
}

// A new group tomato never replaces one that's on, or a group break people picked (they'd lose their next round).
func canStartSession(_ s: GroupSession?, now: Date) -> Bool {
    guard let s, !s.cancelled else { return true }
    if sessionPhase(s, now: now) != .over { return false }
    guard let next = nextRoundStart(s) else { return true }
    return s.nextJoined.isEmpty || next <= now
}

// The group's session line in the menu; minutes are rounded up. `here`: this Mac is in this round.
enum SessionMenu: Equatable { case start, starting, joinCountdown, inIt(Int), otherMac(Int), joinRunning(Int), onBreak(Int), joinBreak(Int) }

func sessionMenu(_ s: GroupSession?, me: String, device: String, here: Bool, now: Date) -> SessionMenu {
    guard let s else { return .start }
    switch sessionPhase(s, now: now) {
    case .countdown:
        return here || otherMacHasIt(s, me: me, device: device) ? .starting : .joinCountdown
    case .running(let left):
        let m = Int((left / 60).rounded(.up))
        return here ? .inIt(m) : otherMacHasIt(s, me: me, device: device) ? .otherMac(m) : .joinRunning(m)
    case .over:
        guard !s.cancelled, !s.nextJoined.isEmpty, let next = nextRoundStart(s) else { return .start }
        let toNext = next.timeIntervalSince(now)
        if toNext <= 0 { return .start }
        if toNext <= Double(countdownSeconds) { return .starting }
        let m = Int((toNext / 60).rounded(.up))
        return s.nextJoined.contains(me) ? .onBreak(m) : .joinBreak(m)
    }
}

// This Mac's minutes that count in a group: only from the day you joined.
func secondsSince(_ local: [String: Double], joined: Date) -> [String: Double] {
    let first = Calendar.current.startOfDay(for: joined)
    return local.filter { key, _ in
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, let day = gregorian.date(from: DateComponents(year: p[0], month: p[1], day: p[2])) else { return false }
        return day >= first
    }
}

func shouldAutoJoin(idleSeconds: Double) -> Bool { idleSeconds < activeMacSeconds }

// I'm in this group tomato, but on another of my Macs: this one shows nothing (or closes its countdown).
func otherMacHasIt(_ s: GroupSession, me: String, device: String) -> Bool {
    s.joined.contains(me) && s.devices[me] != device
}

// What this Mac shows when a group tomato's countdown begins; nil = nothing.
// Already in (I started it here, or picked the group break here) → no question asked.
func countdownMode(_ s: GroupSession, me: String, device: String, autoJoin: Bool, idleSeconds: Double) -> CountdownMode? {
    if otherMacHasIt(s, me: me, device: device) { return nil }
    if s.joined.contains(me) { return s.startedBy == me && s.round == 1 ? .starter : .autoJoin }
    return autoJoin && shouldAutoJoin(idleSeconds: idleSeconds) ? .autoJoin : .invite
}

private let codeAlphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")  // no 0/O, 1/I: easy to type

func makeInviteCode<R: RandomNumberGenerator>(using rng: inout R) -> String {
    "TOMA-" + String((0..<6).map { _ in codeAlphabet.randomElement(using: &rng)! })
}

// Typed codes: any case, spaces, dashes of any kind, quotes or a period around it; "TOMA" optional.
func normalizeCode(_ s: String) -> String? {
    var c = String(s.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
    if c.count == 10, c.hasPrefix("TOMA") { c.removeFirst(4) }  // no O in codes, so TOMA can't be part of one
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
// `id` changes every round; the document itself is always groups/{gid}/sessions/current.
func session(data: [String: Any]) -> GroupSession? {
    guard let id = data["id"] as? String, let startedBy = data["startedBy"] as? String,
          let startAt = data["startAt"] as? Date ?? (data["createdAt"] as? Date).map({ $0 + Double(countdownSeconds) })
    else { return nil }
    return GroupSession(id: id, round: (data["round"] as? NSNumber)?.intValue ?? 1, startedBy: startedBy,
                        starterName: data["starterName"] as? String ?? "", tierName: data["tierName"] as? String ?? "",
                        minutes: (data["minutes"] as? NSNumber)?.doubleValue ?? 0, startAt: startAt,
                        cancelled: data["cancelled"] as? Bool ?? false, joined: data["joined"] as? [String] ?? [],
                        nextJoined: data["nextJoined"] as? [String] ?? [],
                        devices: data["devices"] as? [String: String] ?? [:],
                        plan: (data["plan"] as? [NSNumber])?.map(\.doubleValue) ?? [],
                        nextTierName: data["nextTierName"] as? String,
                        nextMinutes: (data["nextMinutes"] as? NSNumber)?.doubleValue,
                        nextRound: (data["nextRound"] as? NSNumber)?.intValue)
}

enum GroupError: LocalizedError {
    case offline, notSignedIn, noSuchCode, full, notAllowed, busy
    var errorDescription: String? {
        switch self {
        case .offline: "Couldn't reach Tomatime Groups. Check your connection."
        case .notSignedIn: "Sign in with Apple first."
        case .noSuchCode: "No group has that invite code. Check it and try again."
        case .full: "This group is full (6 people)."
        case .notAllowed: "You can't do that in this group."
        case .busy: "A group tomato or group break is already on in this group. Join it from the menu."
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
