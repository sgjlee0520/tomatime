// Tomatime Groups in the menu, and group tomatoes on this Mac: countdown, start together, group break, leaving.
// Firebase reads and writes: GroupStore. Decisions: GroupRules. The countdown screen: Countdown.
import AppKit
import AuthenticationServices

// The group tomato on this Mac (App.group).
struct GroupPlay {
    var gid: String?                          // group whose tomato, or group break, I'm in
    var sid: String?                          // that tomato's round id
    var tier: Tier?                           // its length and color, until the next reset
    var showing: (gid: String, sid: String)?  // countdown on screen
    var joining: String?                      // round this Mac starts at 0
    var seen = Set<String>()                  // rounds whose countdown already came up
    var startTimer: Timer?, advanceTimer: Timer?
    var lastStatus: MemberStatus?
}

private let groupTag = 7_000  // top-level menu items, rebuilt on every change

@MainActor func after(_ date: Date, _ f: @escaping @MainActor () -> Void) -> Timer {
    let t = Timer(fire: date, interval: 0, repeats: false) { _ in MainActor.assumeIsolated { f() } }
    RunLoop.main.add(t, forMode: .common)
    return t
}

extension App {
    var store: GroupStore { .shared }

    func startGroups() {
        store.onChange = { [weak self] in self?.groupsChanged() }
        rebuildGroupMenu()
    }

    func groupsChanged() {
        render()
        rebuildGroupMenu()
        if calendarWindow?.isVisible == true { calendarView.setGroups(store.groups, me: store.uid) }
        guard let me = store.uid else { return }
        for g in store.groups {
            guard let s = store.sessions[g.id] else { continue }
            let phase = sessionPhase(s, now: Date())
            if phase != .over, let fix = roundFix(s) {  // an older Tomatime moved the group on with the old tomato
                store.setTomato(g.id, sid: s.id, tierName: fix.name, minutes: fix.minutes, next: false)
            }
            // Someone in it changed its length. (No `end`: mine had just run out, the red screen is up; on it goes.)
            if group.gid == g.id, group.sid == s.id, !onBreak, case .running(let left) = phase,
               end.map({ abs($0.timeIntervalSince(s.startAt + s.minutes * 60)) > 1 }) ?? (left > 2) {
                countFocus()
                closeOverlay()
                focused = max(1, focused + ((left - (end?.timeIntervalSinceNow ?? 0)) / 60).rounded())
                group.tier = tomatoTier(s.tierName, s.minutes)
                NSSound(named: "Tink")?.play()
                run(left)
            }
            if let shown = group.showing, shown.gid == g.id {
                if shown.sid != s.id || s.cancelled || otherMacHasIt(s, me: me, device: deviceKey) {
                    closeCountdown()
                } else {
                    let (names, waiting) = joinedNames(g, s)
                    countdown?.setJoinedNames(names, waiting: waiting)
                }
            }
            guard case .countdown = phase, group.seen.insert(s.id).inserted, !countdownUp,
                  let mode = countdownMode(s, me: me, device: deviceKey, autoJoin: autoJoins(g.id), idleSeconds: idleSeconds())
            else { continue }
            showCountdown(g, s, mode)
        }
    }

    // MARK: Group tomatoes

    private var countdownUp: Bool {
        guard let (gid, sid) = group.showing, let s = store.sessions[gid], s.id == sid else { return false }
        return s.startAt > Date()
    }

    func showCountdown(_ g: TomatoGroup, _ s: GroupSession, _ mode: CountdownMode) {
        let who = s.startedBy == store.uid ? "You" : s.starterName
        let what = tomatoText(s.tierName, s.minutes), n = examTomatoes(s.plan).count
        let title = s.round > max(n, 1) || s.plan.isEmpty ? (s.round == 1 ? "\(who) started a 🍅 \(what)" : "next group 🍅 \(what)")
            : s.round == 1 ? "\(who) started Exam mode · \(examText(s.plan))" : "Exam mode \(s.round) of \(n) · 🍅 \(what)"
        countdown?.close()
        group.showing = (g.id, s.id)
        countdown = Countdown(title: "\(g.name): \(title)",
                              mode: mode, startAt: s.startAt,
                              note: s.round > 1 && s.joined.contains(store.uid ?? "") ? "You picked the group break" : "Auto-join is on",
                              onJoin: { [weak self] in self?.joinRound(g.id, s.id) },
                              onSkip: { [weak self] in self?.skipRound(g.id, s.id) },
                              onCancel: { [weak self] in self?.store.cancelSession(g.id, sid: s.id); self?.skipRound(g.id, s.id) })
        let (names, waiting) = joinedNames(g, s)
        countdown?.setJoinedNames(names, waiting: waiting)
        if mode != .invite { joinRound(g.id, s.id) }
        scheduleStart(g.id, s.id, at: s.startAt)
    }

    func closeCountdown() {
        countdown?.close()
        group.showing = nil
        group.joining = nil
    }

    func joinedNames(_ g: TomatoGroup, _ s: GroupSession) -> ([String], [String]) {
        let name = { (m: Member) in m.uid == self.store.uid ? "You" : m.name }
        return (g.members.filter { s.joined.contains($0.uid) }.map(name), g.members.filter { !s.joined.contains($0.uid) }.map(name))
    }

    // This Mac will start the round at 0 (and claims it, so my other Macs stand down).
    func joinRound(_ gid: String, _ sid: String) {
        group.joining = sid
        guard let me = store.uid, let s = store.sessions[gid], s.id == sid else { return }
        if !s.joined.contains(me) || s.devices[me] != deviceKey { store.setJoined(gid, sid: sid, joined: true) }
    }

    func skipRound(_ gid: String, _ sid: String) {
        if group.showing?.sid == sid { group.showing = nil }
        if group.joining == sid { group.joining = nil }
        if group.gid == gid { group.gid = nil; group.sid = nil }  // skipping the next round ends the group rhythm
        guard let me = store.uid, let s = store.sessions[gid], s.id == sid else { return }
        if s.joined.contains(me), s.devices[me] == deviceKey { store.setJoined(gid, sid: sid, joined: false) }
    }

    func scheduleStart(_ gid: String, _ sid: String, at date: Date) {
        group.startTimer?.invalidate()
        group.startTimer = after(date) { [weak self] in self?.roundStarts(gid, sid) }
    }

    func roundStarts(_ gid: String, _ sid: String) {
        guard let s = store.sessions[gid], s.id == sid, !s.cancelled else { return }
        if s.startAt.timeIntervalSinceNow > 0.05 { return scheduleStart(gid, sid, at: s.startAt) }  // server time came in later
        guard group.joining == sid, let me = store.uid else { return }
        group.joining = nil
        // This Mac chose to be in; its join may still be on the way to the server. Only my other Mac's claim stops it.
        if !otherMacHasIt(s, me: me, device: deviceKey) { startGroupTomato(gid, s) }
    }

    // Everyone in it ends at the same second; joining late gets the time left. A solo tomato's minutes so far still count.
    func startGroupTomato(_ gid: String, _ s: GroupSession) {
        let endAt = s.startAt + s.minutes * 60
        guard endAt.timeIntervalSinceNow > 1 else { return }
        countFocus()
        closeOverlay()
        group.gid = gid
        group.sid = s.id
        group.tier = tomatoTier(s.tierName, s.minutes)
        exam = nil
        group.advanceTimer?.invalidate()
        onBreak = false
        autoNext = false
        focused = max(1, (endAt.timeIntervalSinceNow / 60).rounded())
        run(endAt.timeIntervalSinceNow)
    }

    // Red screen after a group tomato: 10-minute break that ends as the next group tomato starts.
    // One of the four small buttons under it (tag = which tomato): the same, and the next one is that tomato.
    @objc func groupBreak(_ sender: NSButton) {
        guard let gid = group.gid, let s = store.sessions[gid], s.id == group.sid, joinNextRound(gid, s)
        else { return startBreak(groupBreakMinutes) }  // missed it
        if tiers.indices.contains(sender.tag) {
            store.setTomato(gid, sid: s.id, tierName: tiers[sender.tag].name, minutes: tiers[sender.tag].minutes, next: true)
        }
    }

    // Opt in to the round after `s`: a break that ends as it starts. False when it's under 10 s away.
    // From the red screen, or from the menu while the others are on their group break.
    @discardableResult func joinNextRound(_ gid: String, _ s: GroupSession) -> Bool {
        guard let start = nextRoundStart(s), start.timeIntervalSinceNow > Double(countdownSeconds) else { return false }
        store.setNextJoined(gid, sid: s.id, joined: true)
        countFocus()
        group.gid = gid
        group.sid = s.id
        closeOverlay()
        onBreak = true
        autoNext = false
        exam = nil
        breakMinutes = breakAfter(s) ?? groupBreakMinutes
        run(start.timeIntervalSinceNow)
        group.advanceTimer?.invalidate()  // whoever is first moves everyone opted in to the next round
        group.advanceTimer = after(start - Double(countdownSeconds)) { [weak self] in
            self?.store.advanceRound(gid, from: s.round, startAt: start)
        }
        return true
    }

    // Pause, Reset, a tier, Custom, or a solo button on the red screen: only I leave; the others keep going.
    func leaveGroupTomato() {
        guard let gid = group.gid else { return }
        group.gid = nil
        group.sid = nil
        group.advanceTimer?.invalidate()
        if group.showing?.gid == gid { closeCountdown() }
        guard let me = store.uid, let s = store.sessions[gid], s.devices[me] == deviceKey else { return }
        if s.joined.contains(me), sessionPhase(s, now: Date()) != .over { store.setJoined(gid, sid: s.id, joined: false) }
        if s.nextJoined.contains(me) { store.setNextJoined(gid, sid: s.id, joined: false) }
    }

    @objc func resetTapped() {
        leaveGroupTomato()
        exam = nil
        reset()
    }

    // This Mac's own minutes, under its own device id (never tally(): that already holds my other Macs').
    func publishMinutes() {
        if groupsOn { store.publishSeconds(device: String(deviceKey.dropFirst("focus-".count)), local: localTally()) }
    }

    // Only on change, and only while signed in: writes stay at one per start, pause, break or stop.
    func publishStatus() {
        guard groupsOn, store.signedIn else { return }
        let focusing = end != nil && !onBreak
        let st = MemberStatus(state: end == nil ? .idle : onBreak ? .rest : .focus, tierName: focusing ? tier.name : "",
                              minutes: focusing ? tier.minutes : 0, endsAt: end, sessionID: focusing ? group.sid : nil)
        guard st != group.lastStatus else { return }
        group.lastStatus = st
        store.publish(status: st)
    }

    // The timer, plus friends focusing right now in bold red (unless hidden in Groups ▸).
    func statusTitle(_ base: String) {
        let show = groupsOn && !UserDefaults.standard.bool(forKey: "hideFriendsCount")
        let n = show ? friendsFocusing(store.groups, me: store.uid ?? "", now: Date()) : 0
        guard n > 0, let font = item.button?.font else { item.button?.title = base; return }
        let s = NSMutableAttributedString(string: base, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        s.append(NSAttributedString(string: " \(n)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .bold), .foregroundColor: NSColor.systemRed]))
        item.button?.attributedTitle = s
    }

    func autoJoins(_ gid: String) -> Bool { UserDefaults.standard.bool(forKey: "autoJoin.\(gid)") }

    func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    // MARK: Menu (layout B: one line per group)

    func rebuildGroupMenu() {
        guard groupsOn, let menu = item.menu else { return }
        menu.items.filter { $0.tag == groupTag }.forEach(menu.removeItem)
        var at = menu.indexOfItem(withTitle: "Tomato Calendar…") + 1
        func add(_ mi: NSMenuItem) { mi.tag = groupTag; menu.insertItem(mi, at: at); at += 1 }
        add(.separator())
        store.groups.forEach { add(groupLine($0)) }
        add(groupsItem())
    }

    func groupLine(_ g: TomatoGroup) -> NSMenuItem {
        let now = Date(), me = store.uid
        let busy = g.members.filter { $0.uid != me && effectiveState($0.status, now: now) == .focus }.count
        let n = g.members.count
        let line = NSMenuItem(title: g.name, action: nil, keyEquivalent: "")
        line.attributedTitle = columns("👥 \(g.name)", busy > 0 ? "\(busy) focusing" : "\(n) member\(n == 1 ? "" : "s")", at: 260)
        let sub = NSMenu()
        for m in g.members {
            let icon = switch effectiveState(m.status, now: now) { case .focus: "🍅"; case .rest: "☕"; case .idle: "💤" }
            let mi = NSMenuItem(title: m.name, action: nil, keyEquivalent: "")
            mi.attributedTitle = columns("\(icon) \(m.name)\(m.uid == me ? " (you)" : "")", statusText(m, now: now), at: 300)
            sub.addItem(mi)
        }
        sub.addItem(.separator())
        sub.addItem(sessionItem(g, now: now))
        let auto = groupItem("Auto-join", #selector(toggleAutoJoin), g.id)
        auto.state = autoJoins(g.id) ? .on : .off
        sub.addItem(auto)
        if let code = store.code(of: g.id) { sub.addItem(groupItem("Copy invite code (\(code))", #selector(copyCode), g.id)) }
        if g.ownerUID == me {
            sub.addItem(.separator())
            sub.addItem(groupItem("New invite code…", #selector(newCodeTapped), g.id))
            let others = g.members.filter { $0.uid != me }
            if !others.isEmpty {
                let remove = NSMenuItem(title: "Remove member", action: nil, keyEquivalent: "")
                remove.submenu = NSMenu()
                others.forEach { remove.submenu?.addItem(groupItem("\($0.name)…", #selector(removeTapped), [g.id, $0.uid, $0.name])) }
                sub.addItem(remove)
            }
            sub.addItem(groupItem("Rename group…", #selector(renameTapped), g.id))
        }
        sub.addItem(.separator())
        sub.addItem(groupItem("Leave group…", #selector(leaveTapped), g.id))
        line.submenu = sub
        return line
    }

    func sessionItem(_ g: TomatoGroup, now: Date) -> NSMenuItem {
        let s = store.sessions[g.id]
        let here = s.map { group.joining == $0.id || group.sid == $0.id } ?? false
        let join = { (title: String) in self.groupItem(title, #selector(self.joinGroupTapped), g.id) }
        switch sessionMenu(s, me: store.uid ?? "", device: deviceKey, here: here, now: now) {
        case .start:  // any tomato a solo session can be: the four, or a typed length; or Exam mode
            let start = tomatoChoices("Start group tomato", #selector(startGroupTapped), g.id)
            start.submenu?.addItem(.separator())
            start.submenu?.addItem(groupItem("Exam mode · \(examText(examPlan))", #selector(startGroupExamTapped), g.id))
            return start
        case .starting: return info("Group tomato starting…")
        case .joinCountdown: return join("Group tomato starting — Join")
        case .inIt(let m):  // anyone in it can change its length (not an Exam mode's: the plan sets those)
            guard let s, s.plan.isEmpty else { return info("In this group tomato · \(m) min left\(examNote(s))") }
            return tomatoChoices("In this group tomato · \(m) min left", #selector(changeGroupTapped), g.id,
                                 header: "Change its length, for everyone in it:")
        case .otherMac(let m): return info("In this group tomato on your other Mac · \(m) min left")
        case .joinRunning(let m): return join("Group tomato in progress — Join (\(m) min left)")
        case .onBreak(let m):  // …or pick another tomato for the next round
            guard let s, s.plan.isEmpty else { return info("Group break · next group tomato in \(m) min\(examNote(s))") }
            let next = nextTomato(s)
            return tomatoChoices("Group break · next: \(tomatoText(next.name, next.minutes)) in \(m) min", #selector(changeGroupTapped),
                                 g.id, header: "Change the next group tomato:")
        case .joinBreak(let m): return join("Group break · next group tomato in \(m) min — Join")
        }
    }

    // A line with the four tomatoes and Custom tomato… under it; each carries [group, name, minutes] ([group]: Custom).
    func tomatoChoices(_ title: String, _ action: Selector, _ gid: String, header: String? = nil) -> NSMenuItem {
        let line = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        line.submenu = NSMenu()
        if let header { line.submenu?.addItem(info(header)) }
        for t in tiers {
            let mi = groupItem("\(t.name) tomato · \(Int(t.minutes)) min", action, [gid, t.name, t.minutes] as [Any])
            mi.image = tomato(t.color, size: 16)
            line.submenu?.addItem(mi)
        }
        let typed = groupItem("Custom tomato…", action, [gid] as [Any])
        typed.image = tomato(.systemGray, size: 16)
        line.submenu?.addItem(typed)
        return line
    }

    func tomatoText(_ name: String, _ minutes: Double) -> String {
        name.hasSuffix("-min") ? "\(Int(minutes)) min tomato" : "\(name) tomato · \(Int(minutes)) min"
    }

    // " · Exam mode 2 of 4" for a group's Exam mode; on its break, the tomato that's next.
    func examNote(_ s: GroupSession?) -> String {
        guard let s, !s.plan.isEmpty else { return "" }
        let k = s.round + (sessionPhase(s, now: Date()) == .over ? 1 : 0), n = examTomatoes(s.plan).count
        return k <= n ? " · Exam mode \(k) of \(n)" : ""
    }

    func groupsItem() -> NSMenuItem {
        let mi = NSMenuItem(title: "Groups", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        if !store.signedIn, !codeSignIn { sub.addItem(groupItem("Sign in with Apple…", #selector(signInTapped))) }
        sub.addItem(groupItem("New Group…", #selector(newGroupTapped)))
        sub.addItem(groupItem("Join with Code…", #selector(joinCodeTapped)))
        if store.signedIn { sub.addItem(groupItem(store.myName.map { "Change My Name (\($0))…" } ?? "Set My Name…", #selector(changeNameTapped))) }
        if store.signedIn {
            sub.addItem(groupItem("Sign Out of Groups", #selector(signOutTapped)))
            sub.addItem(groupItem("Delete My Groups Account…", #selector(deleteAccountTapped)))
        }
        sub.addItem(.separator())
        let count = groupItem("Show Friends Focusing in Menu Bar", #selector(toggleFriendsCount))
        count.state = UserDefaults.standard.bool(forKey: "hideFriendsCount") ? .off : .on
        sub.addItem(count)
        mi.submenu = sub
        return mi
    }

    func groupItem(_ title: String, _ action: Selector, _ object: Any? = nil) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = self
        mi.representedObject = object
        return mi
    }

    func info(_ title: String) -> NSMenuItem { NSMenuItem(title: title, action: nil, keyEquivalent: "") }

    // "left" at the margin, "right" right-aligned at `at` points.
    func columns(_ left: String, _ right: String, at: CGFloat) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.tabStops = [NSTextTab(textAlignment: .right, location: at)]
        let font = NSFont.menuFont(ofSize: 0)
        let s = NSMutableAttributedString(string: left + "\t", attributes: [.font: font, .paragraphStyle: p])
        s.append(NSAttributedString(string: right, attributes: [.font: font, .paragraphStyle: p, .foregroundColor: NSColor.secondaryLabelColor]))
        return s
    }

    // MARK: Menu actions

    // [group, tomato name, minutes] from the submenu; just [group] is Custom tomato…, which asks the minutes.
    @objc func startGroupTapped(_ sender: NSMenuItem) {
        guard let (gid, name, minutes) = pickedTomato(sender, button: "Start") else { return }
        groupTask { try await self.store.startSession(gid, tierName: name, minutes: minutes) }
    }

    func pickedTomato(_ sender: NSMenuItem, button: String) -> (gid: String, name: String, minutes: Double)? {
        guard let o = sender.representedObject as? [Any], let gid = o.first as? String else { return nil }
        if o.count == 3, let name = o[1] as? String, let minutes = o[2] as? Double { return (gid, name, minutes) }
        return askMinutes("Custom group tomato", button: button).map { (gid, "\($0)-min", Double($0)) }
    }

    // Exam mode for the group: this Mac's plan, tomatoes and breaks back to back for everyone who joins.
    @objc func startGroupExamTapped(_ sender: NSMenuItem) {
        guard let gid = sender.representedObject as? String else { return }
        let plan = examPlan
        groupTask { try await self.store.startSession(gid, tierName: tomatoName(plan[0]), minutes: plan[0], plan: plan) }
    }

    // While the group tomato runs: its length, for everyone in it. On the group break: the next round's tomato.
    @objc func changeGroupTapped(_ sender: NSMenuItem) {
        guard let (gid, name, minutes) = pickedTomato(sender, button: "Change"), let s = store.sessions[gid] else { return }
        switch sessionPhase(s, now: Date()) {
        case .running:
            guard canResize(s, to: minutes, now: Date()) else {
                return tell("Can't change it to that now.", "The new length has to leave at least a minute, and not in this tomato's last 10 seconds. You can pick the next one on the red screen.")
            }
            store.setTomato(gid, sid: s.id, tierName: name, minutes: minutes, next: false)
        case .over: store.setTomato(gid, sid: s.id, tierName: name, minutes: minutes, next: true)
        case .countdown: break
        }
    }

    // Arrived late, or skipped the countdown and changed your mind.
    @objc func joinGroupTapped(_ sender: NSMenuItem) {
        guard let gid = sender.representedObject as? String, let s = store.sessions[gid] else { return }
        if group.gid != gid { leaveGroupTomato() }
        switch sessionPhase(s, now: Date()) {
        case .countdown: joinRound(gid, s.id); scheduleStart(gid, s.id, at: s.startAt)
        case .running: store.setJoined(gid, sid: s.id, joined: true); startGroupTomato(gid, s)
        case .over: joinNextRound(gid, s)  // the others are on their group break
        }
    }

    @objc func toggleFriendsCount() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "hideFriendsCount"), forKey: "hideFriendsCount")
        render()
        rebuildGroupMenu()
    }

    @objc func toggleAutoJoin(_ sender: NSMenuItem) {
        guard let gid = sender.representedObject as? String else { return }
        UserDefaults.standard.set(!autoJoins(gid), forKey: "autoJoin.\(gid)")
        rebuildGroupMenu()
    }

    @objc func copyCode(_ sender: NSMenuItem) {
        guard let gid = sender.representedObject as? String, let code = store.code(of: gid) else { return }
        copyToPasteboard(code)
    }

    @objc func newCodeTapped(_ sender: NSMenuItem) {
        guard let gid = sender.representedObject as? String,
              confirm("Make a new invite code?", "The old code stops working. People already in the group stay.", "New Code")
        else { return }
        groupTask {
            let code = try await self.store.newCode(gid)
            self.copyToPasteboard(code)
            self.tell("New invite code copied: \(code)", "Send it to the people you want to invite.")
        }
    }

    @objc func removeTapped(_ sender: NSMenuItem) {
        guard let x = sender.representedObject as? [String], x.count == 3,
              confirm("Remove \(x[2]) from the group?", "They can come back only with a new invite.", "Remove")
        else { return }
        groupTask { try await self.store.remove(x[1], from: x[0]) }
    }

    @objc func renameTapped(_ sender: NSMenuItem) {
        guard let gid = sender.representedObject as? String, let g = store.groups.first(where: { $0.id == gid }),
              let name = ask("Rename group", "Everyone in the group sees the new name.", value: g.name, button: "Rename", limit: 40)
        else { return }
        groupTask { try await self.store.rename(gid, to: name) }
    }

    @objc func leaveTapped(_ sender: NSMenuItem) {
        guard let gid = sender.representedObject as? String, let g = store.groups.first(where: { $0.id == gid }),
              confirm("Leave \(g.name)?", "You can come back later with an invite code, if there's room.", "Leave")
        else { return }
        if group.gid == gid { leaveGroupTomato() }
        groupTask { try await self.store.leave(gid) }
    }

    @objc func signInTapped() { groupTask { try await self.readyForGroups() } }

    @objc func signOutTapped() {
        leaveGroupTomato()
        try? store.signOut()
    }

    @objc func deleteAccountTapped() {
        guard confirm("Delete your Groups account?", """
            You leave all your groups, and your name, status and group minutes are deleted. \
            Your tomato minutes on this Mac stay. This can't be undone.
            """, "Delete…")
        else { return }
        leaveGroupTomato()
        groupTask {
            if codeSignIn { try await self.store.deleteAccount(anchor: NSWindow()) } else {
            try await SignInPrompt.run("Delete your Groups account", """
                Confirm with Apple. Tomatime then leaves your groups, deletes your name and account, \
                and stops using your Sign in with Apple.
                """, button: .continue) { try await self.store.deleteAccount(anchor: $0) }
            }
            self.tell("Your Groups account is deleted.")
        }
    }

    @objc func newGroupTapped() {
        groupTask {
            try await self.readyForGroups()
            guard let name = self.ask("New group", "A name for the group, like “Us” or “Physics 115”.", button: "Create", limit: 40)
            else { return }
            let code = try await self.store.createGroup(name: name, unlocked: groupsFree)
            self.copyToPasteboard(code)
            self.tell("Invite code copied: \(code)",
                      "Send it to up to \(maxGroupSize - 1) people. In Tomatime they choose Groups ▸ Join with Code….")
        }
    }

    @objc func joinCodeTapped() {
        groupTask {
            try await self.readyForGroups()
            guard let code = self.ask("Join a group", "Type the invite code you were sent, like TOMA-4K7QM2.",
                                      placeholder: "TOMA-", button: "Join", limit: 20)
            else { return }
            switch try await self.store.join(code: code, hasPass: groupsFree) {
            case .ok: self.tell("You're in!", "The group is now in the Tomatime menu.")
            case .alreadyMember: self.tell("You're already in this group.")
            case .full: self.tell(GroupError.full.localizedDescription)
            case .needsPass: self.tell("This group needs a pass to join.")
            }
        }
    }

    @objc func changeNameTapped() {
        groupTask {
            let old = await self.store.loadName() ?? ""
            guard let name = self.ask("Your name in groups", "The others in your groups see this name.",
                                      value: old, button: "Save", limit: 30)
            else { return }
            try await self.store.setName(name)
        }
    }

    // Signed in, with a display name.
    func readyForGroups() async throws {
        if !store.signedIn, codeSignIn {
            try await store.signIn(anchor: NSWindow())  // no Apple: the invite code and a name are enough
        } else if !store.signedIn {
            try await SignInPrompt.run("Focus together", """
                Groups of up to \(maxGroupSize) people see who's focusing, start tomatoes at the same second, \
                and compare minutes.

                Sign in with Apple so all your Macs count as one member. Tomatime doesn't ask for your email; \
                the others see only the name you type next.
                """, button: .signIn) { try await self.store.signIn(anchor: $0) }
        }
        if await store.loadName() == nil {
            guard let name = ask("Your name in groups", "The others in your groups see this name. You can change it later.",
                                 button: "Save", limit: 30)
            else { throw CancellationError() }
            try await store.setName(name)
        }
    }

    // Runs a group action; failures become one plain alert, and nothing in the solo timer changes.
    func groupTask(_ work: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do { try await work() }
            catch is CancellationError {}
            catch let e as ASAuthorizationError where e.code == .canceled {}
            catch let e as GroupError { tell(e.localizedDescription) }
            catch { tell(GroupError.offline.localizedDescription) }
        }
    }

    // MARK: Alerts

    func copyToPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    func tell(_ title: String, _ info: String = "") {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        NSApp.activate()
        a.runModal()
    }

    func confirm(_ title: String, _ info: String, _ button: String) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        a.addButton(withTitle: button)
        a.addButton(withTitle: "Cancel")
        NSApp.activate()
        return a.runModal() == .alertFirstButtonReturn
    }

    // A one-line answer, trimmed, 1…limit characters; nil = Cancel.
    func ask(_ title: String, _ info: String, value: String = "", placeholder: String = "", button: String, limit: Int) -> String? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = value
        field.placeholderString = placeholder
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        a.accessoryView = field
        a.addButton(withTitle: button)
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        NSApp.activate()
        while a.runModal() == .alertFirstButtonReturn {
            let s = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty, s.count <= limit { return s }
            a.informativeText = "Type 1 to \(limit) characters."
        }
        return nil
    }
}

// A Sign in with Apple window: Apple's own button and what it's for. `action` runs with this window as the anchor
// (signing in, or confirming an account deletion); errors show in the window.
@MainActor final class SignInPrompt: NSObject, NSWindowDelegate {
    private static var open: SignInPrompt?
    private var action: (NSWindow) async throws -> Void = { _ in }
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 240), styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
    private let note = NSTextField(wrappingLabelWithString: "")
    private var done: CheckedContinuation<Void, Error>?

    static func run(_ title: String, _ text: String, button: ASAuthorizationAppleIDButton.ButtonType,
                    action: @escaping (NSWindow) async throws -> Void) async throws {
        open?.window.close()  // one at a time
        let p = SignInPrompt()
        p.action = action
        open = p
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            p.done = c
            p.show(title, text, button)
        }
    }

    private func show(_ title: String, _ text: String, _ type: ASAuthorizationAppleIDButton.ButtonType) {
        let head = NSTextField(labelWithString: title)
        head.font = .systemFont(ofSize: 17, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString: text)
        body.preferredMaxLayoutWidth = 392
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let button = ASAuthorizationAppleIDButton(authorizationButtonType: type, authorizationButtonStyle: dark ? .white : .black)
        button.target = self
        button.action = #selector(signIn)
        NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 240),
                                     button.heightAnchor.constraint(equalToConstant: 36)])
        note.textColor = .systemRed
        let stack = NSStackView(views: [head, body, button, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 20, right: 24)
        window.title = "Tomatime Groups"
        window.contentView = stack
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    @objc private func signIn() {
        note.stringValue = ""
        Task {
            do {
                try await action(window)
                finish(nil)
            } catch let e as ASAuthorizationError where e.code == .canceled {
            } catch let e as GroupError {
                note.stringValue = e.localizedDescription
            } catch {
                note.stringValue = error.localizedDescription
            }
        }
    }

    func windowWillClose(_: Notification) { finish(CancellationError()) }

    private func finish(_ error: Error?) {
        guard let d = done else { return }
        done = nil
        Self.open = nil
        if let error { return d.resume(throwing: error) }  // the window is already closing
        window.delegate = nil
        window.close()
        d.resume()
    }
}
