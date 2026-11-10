// Plain checks for Groups/GroupRules.swift. Run: tools/test.sh
import Foundation

struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

func check(_ ok: Bool, _ what: String, line: Int = #line) {
    precondition(ok, "FAILED line \(line): \(what)")
}

let t0 = Date(timeIntervalSince1970: 1_794_000_000)
let idle = MemberStatus(state: .idle, tierName: "", minutes: 0, endsAt: nil, sessionID: nil)

func focus(_ endsAt: Date) -> MemberStatus {
    MemberStatus(state: .focus, tierName: "Golden", minutes: 45, endsAt: endsAt, sessionID: nil)
}

func mk(_ uid: String, _ status: MemberStatus = idle, joined: Date = t0 - 30 * 86400,
        seconds: [String: [String: Double]] = [:]) -> Member {
    Member(uid: uid, name: uid, joinedAt: joined, hasPass: false, status: status, secondsByDevice: seconds)
}

func group(_ members: [Member], unlocked: Bool = true) -> TomatoGroup {
    TomatoGroup(id: "g", name: "G", ownerUID: members.first?.uid ?? "", memberUIDs: members.map(\.uid),
                unlocked: unlocked, members: members)
}

@main struct RulesCheck {
    static func main() async {
        // joinVerdict
        let two = group([mk("a"), mk("b")])
        check(joinVerdict(two, uid: "new", hasPass: false) == .ok, "unlocked group, no pass → ok")
        var locked = two; locked.unlocked = false
        check(joinVerdict(locked, uid: "new", hasPass: false) == .needsPass, "locked, no pass → needsPass")
        check(joinVerdict(locked, uid: "new", hasPass: true) == .ok, "locked + pass → ok")
        let six = group((1...6).map { mk("m\($0)") })
        check(joinVerdict(six, uid: "new", hasPass: true) == .full, "6 members → full")
        check(joinVerdict(two, uid: "a", hasPass: false) == .alreadyMember, "already a member")

        // effectiveState
        check(effectiveState(focus(t0 - 1), now: t0) == .idle, "focus past end → idle")
        check(effectiveState(focus(t0 + 60), now: t0) == .focus, "focus before end → focus")
        let pastBreak = MemberStatus(state: .rest, tierName: "", minutes: 10, endsAt: t0 - 5, sessionID: nil)
        check(effectiveState(pastBreak, now: t0) == .idle, "break past end → idle")

        // friendsFocusing: unique people, not me, not expired
        let g1 = group([mk("me", focus(t0 + 600)), mk("A", focus(t0 + 600))])
        let g2 = group([mk("me"), mk("A", focus(t0 + 600)), mk("B", focus(t0 + 60)), mk("C", focus(t0 - 60))])
        check(friendsFocusing([g1, g2], me: "me", now: t0) == 2, "A and B focusing")

        // statusText
        check(statusText(mk("x", focus(t0 + 31 * 60)), now: t0) == "Golden · 31 min", "focus text")
        let onBreak = MemberStatus(state: .rest, tierName: "", minutes: 10, endsAt: t0 + 4 * 60, sessionID: nil)
        check(statusText(mk("x", onBreak), now: t0) == "break · 4 min", "break text")
        check(statusText(mk("x", seconds: ["d": [dayKey(t0): 2700]]), now: t0) == "45 min today", "idle text")

        // memberSeconds
        let both = mk("x", joined: t0, seconds: ["a": [dayKey(t0): 600], "b": [dayKey(t0): 300]])
        check(memberSeconds(both, day: t0) == 900, "devices add up")
        let early = mk("x", joined: t0, seconds: ["a": [dayKey(t0 - 86400): 600]])
        check(memberSeconds(early, day: t0 - 86400) == 0, "before joining → 0")

        // groupDayMinutes
        let dm = group([mk("p", seconds: ["a": [dayKey(t0): 1500]]), mk("q", seconds: ["b": [dayKey(t0): 1200]])])
        check(groupDayMinutes(dm, days: [t0 - 86400, t0]) == [0, 45], "group minutes per day")

        // weeklyRanking: this week only, sorted, ties alphabetical
        var cal = Calendar.current
        cal.firstWeekday = 1
        let today = dayKey(t0), lastWeek = dayKey(t0 - 8 * 86400)
        let ranked = weeklyRanking(group([
            mk("Jun", seconds: ["d": [today: 230 * 60, lastWeek: 300 * 60]]),
            mk("Alex", seconds: ["d": [today: 365 * 60]]),
            mk("Mina", seconds: ["d": [today: 580 * 60]]),
            mk("You", seconds: ["d": [today: 495 * 60]]),
        ]), now: t0, calendar: cal)
        check(ranked.map(\.name) == ["Mina", "You", "Alex", "Jun"], "ranking order")
        check(ranked.last?.minutes == 230, "last week not counted")
        let tie = weeklyRanking(group([mk("Zed", seconds: ["d": [today: 600]]), mk("Amy", seconds: ["d": [today: 600]])]),
                                now: t0, calendar: cal)
        check(tie.map(\.name) == ["Amy", "Zed"], "ties alphabetical")

        // sessionPhase
        func sess(startAt: Date, minutes: Double = 25, cancelled: Bool = false) -> GroupSession {
            GroupSession(id: "s", round: 1, startedBy: "a", starterName: "A", tierName: "Red", minutes: minutes,
                         startAt: startAt, cancelled: cancelled, joined: [], nextJoined: [])
        }
        check(sessionPhase(sess(startAt: t0 + 7), now: t0) == .countdown(7), "countdown 7")
        check(sessionPhase(sess(startAt: t0 + 6.2), now: t0) == .countdown(7), "countdown rounds up")
        check(sessionPhase(sess(startAt: t0 - 7 * 60), now: t0) == .running(1080), "running, 18 min left")
        check(sessionPhase(sess(startAt: t0 - 30 * 60), now: t0) == .over, "over")
        check(sessionPhase(sess(startAt: t0 + 5, cancelled: true), now: t0) == .over, "cancelled → over")

        // nextRoundStart, shouldAutoJoin
        check(nextRoundStart(after: t0) == t0 + 600, "next round 10 min later")
        check(shouldAutoJoin(idleSeconds: 30), "active Mac auto-joins")
        check(!shouldAutoJoin(idleSeconds: 150), "idle Mac does not")

        // invite codes
        var rng = SplitMix(state: 42)
        let code = makeInviteCode(using: &rng)
        check(code.range(of: "^TOMA-[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{6}$", options: .regularExpression) != nil, "code format: \(code)")
        check(normalizeCode(" toma-4k7qm2 ") == "TOMA-4K7QM2", "lowercase + spaces")
        check(normalizeCode("4k7qm2") == "TOMA-4K7QM2", "no prefix")
        check(normalizeCode("4K7Q") == nil, "too short")
        check(normalizeCode("TOMA-4K7QM0") == nil, "0 not allowed")

        // Firestore boundary
        let s = MemberStatus(state: .focus, tierName: "Red", minutes: 25, endsAt: t0 + 100, sessionID: "s1")
        let m = member(uid: "u", data: ["name": "Mina", "joinedAt": t0, "hasPass": true, "status": statusData(s),
                                        "secondsByDevice": ["d": [today: 60.0]]])
        check(m?.status == s && m?.name == "Mina" && m?.hasPass == true && m?.secondsByDevice["d"]?[today] == 60,
              "member round trip")
        let first = session(id: "x", data: ["round": 1, "startedBy": "a", "starterName": "A", "tierName": "Red",
                                            "minutes": 25.0, "createdAt": t0, "cancelled": false, "joined": ["a"]])
        check(first?.startAt == t0 + 10 && first?.nextJoined == [], "round 1 starts 10 s after createdAt")
        let later = session(id: "x", data: ["round": 2, "startedBy": "a", "starterName": "A", "tierName": "Red",
                                            "minutes": 25.0, "createdAt": t0, "startAt": t0 + 900, "cancelled": false])
        check(later?.startAt == t0 + 900, "stored startAt wins")

        // withTimeout gives up on work that ignores cancellation (Firestore while offline)
        let began = Date()
        var timedOut = false
        do {
            try await withTimeout(0.2) {
                await withCheckedContinuation { c in DispatchQueue.global().asyncAfter(deadline: .now() + 3) { c.resume() } }
            }
        } catch GroupError.offline { timedOut = true } catch {}
        check(timedOut && Date().timeIntervalSince(began) < 1, "timeout returns in time (took \(Date().timeIntervalSince(began)) s)")

        print("rules ok")
    }
}
