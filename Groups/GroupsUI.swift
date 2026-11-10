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
            if let shown = group.showing, shown.gid == g.id {
                if shown.sid != s.id || s.cancelled || otherMacHasIt(s, me: me, device: deviceKey) {
                    closeCountdown()
                } else {
                    let (names, waiting) = joinedNames(g, s)
                    countdown?.setJoinedNames(names, waiting: waiting)
                }
            }
            guard case .countdown = sessionPhase(s, now: Date()), group.seen.insert(s.id).inserted, !countdownUp,
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
        let what = "\(s.tierName) tomato · \(Int(s.minutes)) min"
        countdown?.close()
        group.showing = (g.id, s.id)
        countdown = Countdown(title: s.round == 1 ? "\(g.name): \(who) started a 🍅 \(what)" : "\(g.name): next group 🍅 \(what)",
                              mode: mode, startAt: s.startAt,
                              note: s.round > 1 && s.joined.contains(store.uid ?? "") ? "You picked the group break" : "Auto-join is on",
                              onJoin: { [weak self] in self?.joinRound(g.id, s.id) },
                              onSkip: { [weak self] in self?.skipRound(g.id, s.id) },
                              onCancel: { [weak self] in self?.store.cancelSession(g.id); self?.skipRound(g.id, s.id) })
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
        if !s.joined.contains(me) || s.devices[me] != deviceKey { store.setJoined(gid, joined: true) }
    }

    func skipRound(_ gid: String, _ sid: String) {
        if group.showing?.sid == sid { group.showing = nil }
        if group.joining == sid { group.joining = nil }
        if group.gid == gid { group.gid = nil; group.sid = nil }  // skipping the next round ends the group rhythm
        guard let me = store.uid, let s = store.sessions[gid], s.id == sid else { return }
        if s.joined.contains(me), s.devices[me] == deviceKey { store.setJoined(gid, joined: false) }
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
        if s.joined.contains(me), !otherMacHasIt(s, me: me, device: deviceKey) { startGroupTomato(gid, s) }
    }

    // Everyone in it ends at the same second; joining late gets the time left. A solo tomato's minutes so far still count.
    func startGroupTomato(_ gid: String, _ s: GroupSession) {
        let endAt = s.startAt + s.minutes * 60
        guard endAt.timeIntervalSinceNow > 1 else { return }
        countFocus()
        closeOverlay()
        group.gid = gid
        group.sid = s.id
        group.tier = Tier(name: s.tierName, minutes: s.minutes,
                          color: tiers.first { $0.name == s.tierName }?.color ?? tiers.last { $0.minutes <= s.minutes }?.color ?? tiers[0].color)
        group.advanceTimer?.invalidate()
        onBreak = false
        autoNext = false
        focused = max(1, (endAt.timeIntervalSinceNow / 60).rounded())
        run(endAt.timeIntervalSinceNow)
    }

    // Red screen after a group tomato: 10-minute break that ends as the next group tomato starts.
    @objc func groupBreak() {
        guard let gid = group.gid, let s = store.sessions[gid], s.id == group.sid else { return startBreak(groupBreakMinutes) }
        let start = nextRoundStart(after: s.startAt + s.minutes * 60)
        guard start.timeIntervalSinceNow > Double(countdownSeconds) else { return startBreak(groupBreakMinutes) }  // missed it
        store.setNextJoined(gid, joined: true)
        closeOverlay()
        onBreak = true
        autoNext = false
        run(start.timeIntervalSinceNow)
        group.advanceTimer?.invalidate()  // whoever is first moves everyone opted in to the next round
        group.advanceTimer = after(start - Double(countdownSeconds)) { [weak self] in
            self?.store.advanceRound(gid, from: s.round, startAt: start)
        }
    }

    // Pause, Reset, a tier, Custom, or a solo button on the red screen: only I leave; the others keep going.
    func leaveGroupTomato() {
        guard let gid = group.gid else { return }
        group.gid = nil
        group.sid = nil
        group.advanceTimer?.invalidate()
        if group.showing?.gid == gid { closeCountdown() }
        guard let me = store.uid, let s = store.sessions[gid], s.devices[me] == deviceKey else { return }
        if s.joined.contains(me), sessionPhase(s, now: Date()) != .over { store.setJoined(gid, joined: false) }
        if s.nextJoined.contains(me) { store.setNextJoined(gid, joined: false) }
    }

    @objc func resetTapped() {
        leaveGroupTomato()
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
        let start = groupItem("Start group tomato · \(Int(tier.minutes)) min", #selector(startGroupTapped), g.id)
        guard let s = store.sessions[g.id], let me = store.uid else { return start }
        switch sessionPhase(s, now: now) {
        case .over:
            return start
        case .countdown:
            let mine = group.joining == s.id || otherMacHasIt(s, me: me, device: deviceKey)
            return mine ? info("Group tomato starting…") : groupItem("Group tomato starting — Join", #selector(joinGroupTapped), g.id)
        case .running(let left):
            let m = Int((left / 60).rounded(.up))
            return group.sid == s.id ? info("In this group tomato · \(m) min left")
                : groupItem("Group tomato in progress — Join (\(m) min left)", #selector(joinGroupTapped), g.id)
        }
    }

    func groupsItem() -> NSMenuItem {
        let mi = NSMenuItem(title: "Groups", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        if !store.signedIn { sub.addItem(groupItem("Sign in with Apple…", #selector(signInTapped))) }
        sub.addItem(groupItem("New Group…", #selector(newGroupTapped)))
        sub.addItem(groupItem("Join with Code…", #selector(joinCodeTapped)))
        if store.signedIn { sub.addItem(groupItem(store.myName.map { "Change My Name (\($0))…" } ?? "Set My Name…", #selector(changeNameTapped))) }
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

    @objc func startGroupTapped(_ sender: NSMenuItem) {
        guard let gid = sender.representedObject as? String else { return }
        let t = tier
        groupTask { try await self.store.startSession(gid, tierName: t.name, minutes: t.minutes) }
    }

    // Arrived late, or skipped the countdown and changed your mind.
    @objc func joinGroupTapped(_ sender: NSMenuItem) {
        guard let gid = sender.representedObject as? String, let s = store.sessions[gid] else { return }
        if group.gid != gid { leaveGroupTomato() }
        switch sessionPhase(s, now: Date()) {
        case .countdown: joinRound(gid, s.id); scheduleStart(gid, s.id, at: s.startAt)
        case .running: store.setJoined(gid, joined: true); startGroupTomato(gid, s)
        case .over: break
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
        if !store.signedIn { try await SignInPrompt.run() }
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

// The Sign in with Apple window: Apple's own button, and what signing in is for.
@MainActor final class SignInPrompt: NSObject, NSWindowDelegate {
    private static var open: SignInPrompt?
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 240), styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
    private let note = NSTextField(wrappingLabelWithString: "")
    private var done: CheckedContinuation<Void, Error>?

    static func run() async throws {
        open?.window.close()  // one at a time
        let p = SignInPrompt()
        open = p
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            p.done = c
            p.show()
        }
    }

    private func show() {
        let head = NSTextField(labelWithString: "Focus together")
        head.font = .systemFont(ofSize: 17, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString: """
            Groups of up to \(maxGroupSize) people see who's focusing, start tomatoes at the same second, \
            and compare minutes.

            Sign in with Apple so all your Macs count as one member. Tomatime doesn't ask for your email; \
            the others see only the name you type next.
            """)
        body.preferredMaxLayoutWidth = 392
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let button = ASAuthorizationAppleIDButton(authorizationButtonType: .signIn, authorizationButtonStyle: dark ? .white : .black)
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
                try await GroupStore.shared.signIn(anchor: window)
                finish(nil)
            } catch let e as ASAuthorizationError where e.code == .canceled {
            } catch let e as GroupError {
                note.stringValue = e.localizedDescription
            } catch {
                note.stringValue = "Couldn't sign in: \(error.localizedDescription)"
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
