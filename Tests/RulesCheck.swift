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
                         startAt: startAt, cancelled: cancelled, joined: [], nextJoined: [], devices: [:])
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
        check(normalizeCode("toma 4k7qm2") == "TOMA-4K7QM2", "space instead of the dash")
        check(normalizeCode("TOMA4K7QM2") == "TOMA-4K7QM2", "no dash")
        check(normalizeCode("TOMA–4K7QM2") == "TOMA-4K7QM2", "en dash")
        check(normalizeCode("TOMA-4K7QM2.") == "TOMA-4K7QM2", "trailing period")
        check(normalizeCode("“TOMA-4K7QM2”") == "TOMA-4K7QM2", "quoted")
        check(normalizeCode("4K7 QM2") == "TOMA-4K7QM2", "space inside")
        check(normalizeCode("TOMA-4K7QM22") == nil, "too long")

        // Firestore boundary
        let s = MemberStatus(state: .focus, tierName: "Red", minutes: 25, endsAt: t0 + 100, sessionID: "s1")
        let m = member(uid: "u", data: ["name": "Mina", "joinedAt": t0, "hasPass": true, "status": statusData(s),
                                        "secondsByDevice": ["d": [today: 60.0]]])
        check(m?.status == s && m?.name == "Mina" && m?.hasPass == true && m?.secondsByDevice["d"]?[today] == 60,
              "member round trip")
        let first = session(data: ["id": "r1", "round": 1, "startedBy": "a", "starterName": "A", "tierName": "Red",
                                   "minutes": 25.0, "createdAt": t0, "cancelled": false, "joined": ["a"],
                                   "devices": ["a": "macA"]])
        check(first?.startAt == t0 + 10 && first?.nextJoined == [], "round 1 starts 10 s after createdAt")
        check(first?.id == "r1" && first?.devices == ["a": "macA"], "round id and devices come from the data")
        let later = session(data: ["id": "r2", "round": 2, "startedBy": "a", "starterName": "A", "tierName": "Red",
                                   "minutes": 25.0, "createdAt": t0, "startAt": t0 + 900, "cancelled": false])
        check(later?.startAt == t0 + 900 && later?.devices == [:], "stored startAt wins")

        // countdownMode: what this Mac shows when a group tomato's countdown begins (nil = nothing)
        func cd(round: Int = 1, joined: [String] = ["a"], devices: [String: String] = ["a": "macA"]) -> GroupSession {
            GroupSession(id: "s", round: round, startedBy: "a", starterName: "A", tierName: "Red", minutes: 25,
                         startAt: t0 + 10, cancelled: false, joined: joined, nextJoined: [], devices: devices)
        }
        check(countdownMode(cd(), me: "a", device: "macA", autoJoin: false, idleSeconds: 0) == .starter, "starter's Mac")
        check(countdownMode(cd(), me: "a", device: "macB", autoJoin: true, idleSeconds: 0) == nil, "starter's other Mac: nothing")
        check(countdownMode(cd(), me: "b", device: "macC", autoJoin: false, idleSeconds: 0) == .invite, "invite")
        check(countdownMode(cd(), me: "b", device: "macC", autoJoin: true, idleSeconds: 30) == .autoJoin, "auto-join, Mac in use")
        check(countdownMode(cd(), me: "b", device: "macC", autoJoin: true, idleSeconds: 300) == .invite, "auto-join, idle Mac: asks")
        let next = cd(round: 2, joined: ["a", "b"], devices: ["a": "macA", "b": "macC"])
        check(countdownMode(next, me: "a", device: "macA", autoJoin: false, idleSeconds: 999) == .autoJoin, "next round: no Cancel")
        check(countdownMode(next, me: "b", device: "macC", autoJoin: false, idleSeconds: 999) == .autoJoin, "next round: in via break")
        check(countdownMode(next, me: "b", device: "macD", autoJoin: true, idleSeconds: 0) == nil, "my other Mac joined")
        check(otherMacHasIt(next, me: "b", device: "macD") && !otherMacHasIt(next, me: "b", device: "macC")
              && !otherMacHasIt(cd(), me: "b", device: "macC"), "otherMacHasIt")

        // canStartSession: a new group tomato never wipes out one that's on, or a group break with people in it
        func gs(startAt: Date, joined: [String] = ["a"], nextJoined: [String] = [], devices: [String: String] = ["a": "macA"],
                cancelled: Bool = false) -> GroupSession {
            GroupSession(id: "s", round: 1, startedBy: "a", starterName: "A", tierName: "Red", minutes: 25, startAt: startAt,
                         cancelled: cancelled, joined: joined, nextJoined: nextJoined, devices: devices)
        }
        let groupBreak = gs(startAt: t0 - 27 * 60, nextJoined: ["a"])  // ended 2 min ago; next round at t0 + 8 min
        check(canStartSession(nil, now: t0), "nothing yet")
        check(!canStartSession(gs(startAt: t0 + 5), now: t0), "countdown on")
        check(!canStartSession(gs(startAt: t0 - 60), now: t0), "tomato running")
        check(canStartSession(gs(startAt: t0 - 30 * 60), now: t0), "over, nobody on the group break")
        check(!canStartSession(groupBreak, now: t0), "group break with people in it")
        check(canStartSession(groupBreak, now: t0 + 600), "break over and nobody moved on")
        check(canStartSession(gs(startAt: t0 + 5, cancelled: true), now: t0), "cancelled")

        // sessionMenu: the group's session line in the menu
        let running = gs(startAt: t0 - 7 * 60)  // 18 min left
        check(sessionMenu(nil, me: "b", device: "macB", here: false, now: t0) == .start, "menu: start")
        check(sessionMenu(gs(startAt: t0 + 5), me: "b", device: "macB", here: false, now: t0) == .joinCountdown, "menu: join countdown")
        check(sessionMenu(gs(startAt: t0 + 5), me: "b", device: "macB", here: true, now: t0) == .starting, "menu: joined here")
        check(sessionMenu(gs(startAt: t0 + 5), me: "a", device: "macB", here: false, now: t0) == .starting, "menu: other Mac joined")
        check(sessionMenu(running, me: "b", device: "macB", here: false, now: t0) == .joinRunning(18), "menu: late join")
        check(sessionMenu(running, me: "a", device: "macA", here: true, now: t0) == .inIt(18), "menu: in it here")
        check(sessionMenu(running, me: "a", device: "macB", here: false, now: t0) == .otherMac(18), "menu: in it on my other Mac")
        check(sessionMenu(groupBreak, me: "b", device: "macB", here: false, now: t0) == .joinBreak(8), "menu: join the group break")
        check(sessionMenu(groupBreak, me: "a", device: "macA", here: true, now: t0) == .onBreak(8), "menu: on the group break")
        check(sessionMenu(groupBreak, me: "b", device: "macB", here: false, now: t0 + 475) == .starting, "menu: next round about to start")
        check(sessionMenu(gs(startAt: t0 - 30 * 60), me: "b", device: "macB", here: false, now: t0) == .start, "menu: over")

        // Day keys are Gregorian whatever this Mac's calendar (tools/test.sh reruns this with a Thai Buddhist calendar)
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = .current
        let c = gregorian.dateComponents([.year, .month, .day], from: t0)
        check(dayKey(t0) == "\(c.year!)-\(c.month!)-\(c.day!)", "Gregorian day key, got \(dayKey(t0))")
        check(secondsSince([dayKey(t0 - 86400): 60, dayKey(t0): 120, dayKey(t0 + 86400): 30], joined: t0)
              == [dayKey(t0): 120, dayKey(t0 + 86400): 30], "minutes count from the day you joined")

        // withTimeout gives up on work that ignores cancellation (Firestore while offline)
        let began = Date()
        var timedOut = false
        do {
            try await withTimeout(0.2) {
                await withCheckedContinuation { c in DispatchQueue.global().asyncAfter(deadline: .now() + 3) { c.resume() } }
            }
        } catch GroupError.offline { timedOut = true } catch {}
        check(timedOut && Date().timeIntervalSince(began) < 1, "timeout returns in time (took \(Date().timeIntervalSince(began)) s)")

        // Shared timer (Shared/TomatoTimer.swift): one document Mac, iPhone and Watch all follow
        let now = t0.timeIntervalSince1970
        let red = TimerState.start(tier: "Red", minutes: 25, phase: .focus, by: "mac", now: t0)
        check(red.endAt == now + 1500 && red.running && red.by == "mac" && red.at == now, "start sets endAt from minutes")
        check(red.remaining(now: t0 + 100) == 1400, "remaining while running")
        check(red.remaining(now: t0 + 9999) == 0, "remaining never below 0")
        let held = red.paused(by: "phone", now: t0 + 100)
        check(held.left == 1400 && !held.running && held.endAt == nil && held.by == "phone", "pause keeps what is left")
        check(held.remaining(now: t0 + 5000) == 1400, "paused time does not run")
        let again = held.resumed(by: "watch", now: t0 + 500)
        check(again.endAt == now + 1900 && again.running && again.by == "watch", "resume restarts from what was left")
        check(red.focusModeOn(now: t0 + 1) && !red.focusModeOn(now: t0 + 1500), "Focus on only before the end")
        check(!held.focusModeOn(now: t0 + 101), "no Focus while paused")
        check(!TimerState.start(tier: "Break", minutes: 5, phase: .rest, by: "m", now: t0).focusModeOn(now: t0 + 1), "no Focus on a break")
        check(!TimerState.idle(by: "m", now: t0).focusModeOn(now: t0), "no Focus when idle")
        check(TimerState(data: red.data) == red && TimerState(data: held.data) == held, "survives a Firestore round trip")
        check(TimerState(data: ["tier": "Red"]) == nil, "no phase → not a timer")
        check(sameTimer(red, TimerState.start(tier: "Red", minutes: 25, phase: .focus, by: "phone", now: t0 + 0.4)), "same tomato, other device")
        check(!sameTimer(red, held) && !sameTimer(nil, red) && !sameTimer(red, again), "pause / resume are changes")
        check(sameTimer(.idle(by: "a", now: t0), .idle(by: "b", now: t0 + 9)), "idle is idle")
        check(sameTimer(held, held.paused(by: "x", now: t0)), "paused twice at the same point is the same")
        check(!isNewSession(red, held, now: t0 + 100) && !isNewSession(held, again, now: t0 + 500), "pause/resume: same tomato")
        check(isNewSession(nil, red, now: t0) && isNewSession(red, .start(tier: "Golden", minutes: 45, phase: .focus, by: "m", now: t0), now: t0), "new tier: new tomato")
        check(isNewSession(red, red, now: t0 + 1500), "after it ran out: new tomato")
        check(hex(Data([0, 171, 255])) == "00abff", "hex tokens")
        check(clockFraction(red, now: t0 + 750) == 0.5 && clockFraction(red, now: t0 + 9999) == 0, "red clock empties as time runs")
        check(abs(clockFraction(held, now: t0 + 5000) - 1400.0 / 1500) < 1e-9, "paused clock holds")
        check(clockFraction(.idle(by: "m", now: t0), now: t0) == 1, "idle clock is full")
        check(tomatoTiers.map(\.minutes) == [20, 25, 45, 60], "the four tiers")

        print("rules ok")
    }
}
