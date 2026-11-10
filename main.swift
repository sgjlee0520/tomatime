// Tomatime: menu-bar tomato focus timer. Build, install, run: ./tools/run-local.sh [--fast]
// --fast makes every "minute" one second, for testing.
import AppKit
import ServiceManagement

struct Tier { let name: String; let minutes: Double; let color: NSColor }

let tiers = [
    Tier(name: "Green", minutes: 20, color: NSColor(srgbRed: 0.45, green: 0.78, blue: 0.25, alpha: 1)),
    Tier(name: "Red", minutes: 25, color: NSColor(srgbRed: 0.90, green: 0.20, blue: 0.15, alpha: 1)),
    Tier(name: "Golden", minutes: 45, color: NSColor(srgbRed: 1.00, green: 0.76, blue: 0.10, alpha: 1)),
    Tier(name: "Diamond", minutes: 60, color: NSColor(srgbRed: 0.55, green: 0.88, blue: 1.00, alpha: 1)),
]
let maxFocusMinutes = 60.0
let unit: Double = CommandLine.arguments.contains("--fast") ? 1 : 60  // seconds per "minute"

// Tomato minutes: focus seconds per local day, e.g. ["2026-11-8": 4500]. --fast and --emulator keep a separate tally.
let statsKey = unit == 60 && !useEmulator ? "focusSeconds" : "focusSecondsFast"


// iCloud sync (real minutes only): each Mac publishes its own tally under its own key and totals add
// them up, so two Macs never overwrite each other. Needs an Apple-signed build; elsewhere it does nothing.
let cloud = NSUbiquitousKeyValueStore.default
let syncs = unit == 60 && !useEmulator
let deviceKey: String = {
    let id = UserDefaults.standard.string(forKey: "deviceID") ?? UUID().uuidString
    UserDefaults.standard.set(id, forKey: "deviceID")
    return "focus-" + id
}()

func localTally() -> [String: Double] { UserDefaults.standard.dictionary(forKey: statsKey) as? [String: Double] ?? [:] }

// This Mac's seconds per day plus every other Mac's from iCloud.
func tally() -> [String: Double] {
    var all = localTally()
    guard syncs else { return all }
    for (key, value) in cloud.dictionaryRepresentation where key.hasPrefix("focus-") && key != deviceKey {
        for (day, secs) in value as? [String: Double] ?? [:] { all[day, default: 0] += secs }
    }
    return all
}

func pushToCloud() { if syncs { cloud.set(localTally(), forKey: deviceKey) } }

func mins(_ secs: Double?) -> Int { Int(((secs ?? 0) + 0.5) / 60) }

func todayText() -> String {
    let m = mins(tally()[dayKey()])
    return "\(m) tomato minute\(m == 1 ? "" : "s") today"
}

func hm(_ m: Int) -> String { m < 60 ? "\(m)m" : m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m" }

// "Tomato intensity": one month, each day shaded by its tomato minutes (one hue: faint = little, deep = a lot).
// With groups, a tab per group shows everyone's minutes added up, and this week's ranking below.
final class CalendarView: NSView {
    static let steps: [(from: Int, label: String)] = [(0, "0"), (1, "1m"), (25, "25m"), (60, "1h"), (120, "2h"), (240, "4h+")]
    static let alphas: [CGFloat] = [0, 0.2, 0.4, 0.6, 0.8, 1]
    let cal = Calendar.current
    let cell = NSSize(width: 60, height: 50), gap: CGFloat = 4, pad: CGFloat = 20
    var month = Date()  // any day in the month shown
    // ponytail: one segment per group; very many groups or long names overflow the 484-pt window
    let tabs = NSSegmentedControl(labels: ["Me"], trackingMode: .selectOne, target: nil, action: nil)
    var arrows: [NSButton] = []
    var groups: [TomatoGroup] = []
    var me: String?
    var groupID: String?  // nil = Me
    var group: TomatoGroup? { groups.first { $0.id == groupID } }
    var y0: CGFloat { tabs.isHidden ? pad : pad + 36 }  // where the month title starts
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 7 * 60 + 6 * 4 + 40, height: 520))
        for (title, step) in [("‹", -1), ("›", 1)] {
            let b = NSButton(title: title, target: self, action: #selector(shift))
            b.tag = step
            b.frame = NSRect(x: step < 0 ? pad : bounds.width - pad - 40, y: pad, width: 40, height: 28)
            b.setAccessibilityLabel(step < 0 ? "Previous month" : "Next month")
            arrows.append(b)
            addSubview(b)
        }
        tabs.target = self
        tabs.action = #selector(pickTab)
        tabs.isHidden = true
        addSubview(tabs)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc func shift(_ b: NSButton) {
        month = cal.date(byAdding: .month, value: b.tag, to: month)!
        needsDisplay = true
    }

    // Tabs: Me + each group (none without groups). A tab whose group is gone falls back to Me.
    func setGroups(_ groups: [TomatoGroup], me: String?) {
        self.groups = groups
        self.me = me
        if group == nil { groupID = nil }
        let labels = ["Me"] + groups.map(\.name)
        tabs.segmentCount = labels.count
        for (i, label) in labels.enumerated() { tabs.setLabel(label, forSegment: i); tabs.setWidth(0, forSegment: i) }
        tabs.selectedSegment = groups.firstIndex { $0.id == groupID }.map { $0 + 1 } ?? 0
        tabs.isHidden = groups.isEmpty
        tabs.sizeToFit()
        tabs.frame.origin = NSPoint(x: (bounds.width - tabs.frame.width) / 2, y: pad)
        arrows.forEach { $0.frame.origin.y = y0 }
        fit()
        needsDisplay = true
    }

    @objc func pickTab() {
        groupID = tabs.selectedSegment == 0 ? nil : groups[tabs.selectedSegment - 1].id
        fit()
        needsDisplay = true
    }

    // The month, plus the ranking rows on a group tab. The window keeps its top edge.
    func fit() {
        let h = y0 + 500 + (group.map { 40 + CGFloat($0.members.count) * 22 } ?? 0)
        guard h != frame.height else { return }
        setFrameSize(NSSize(width: frame.width, height: h))
        guard let w = window else { return }
        var f = w.frameRect(forContentRect: NSRect(origin: .zero, size: frame.size))
        f.origin = NSPoint(x: w.frame.minX, y: w.frame.maxY - f.height)
        w.setFrame(f, display: true)
    }

    func text(_ s: String, _ p: NSPoint, _ size: CGFloat, _ color: NSColor = .labelColor,
              weight: NSFont.Weight = .regular, centered: Bool = true, right: Bool = false) {
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
        let w = (s as NSString).size(withAttributes: a).width
        let dx = right ? w : centered ? w / 2 : 0
        (s as NSString).draw(at: NSPoint(x: p.x - dx, y: p.y), withAttributes: a)
    }

    override func draw(_: NSRect) {
        let first = cal.dateInterval(of: .month, for: month)!.start
        let days = cal.range(of: .day, in: .month, for: first)!.map { cal.date(byAdding: .day, value: $0 - 1, to: first)! }
        let g = group
        let minutes: [Int]
        if let g {
            minutes = groupDayMinutes(g, days: days)
        } else {
            let all = tally()
            minutes = days.map { mins(all[dayKey($0)]) }
        }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        let sum = hm(minutes.reduce(0, +))
        let title = f.string(from: first), total = g == nil ? "\(sum) of tomatoes this month" : "group total \(sum) this month"
        text(title, NSPoint(x: bounds.midX, y: y0), 18, weight: .semibold)
        text(total, NSPoint(x: bounds.midX, y: y0 + 26), 12, .secondaryLabelColor)

        let top = y0 + 64, stride = cell.width + gap
        for col in 0..<7 {
            let symbol = cal.shortWeekdaySymbols[(col + cal.firstWeekday - 1) % 7]
            text(symbol, NSPoint(x: pad + CGFloat(col) * stride + cell.width / 2, y: top), 11, .secondaryLabelColor)
        }
        let offset = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        for (i, day) in days.enumerated() {
            let slot = offset + i
            let r = NSRect(x: pad + CGFloat(slot % 7) * stride, y: top + 20 + CGFloat(slot / 7) * (cell.height + gap),
                           width: cell.width, height: cell.height)
            let box = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
            let level = Self.steps.lastIndex { minutes[i] >= $0.from }!
            (level == 0 ? NSColor.quaternaryLabelColor : NSColor.systemRed.withAlphaComponent(Self.alphas[level])).setFill()
            box.fill()
            if cal.isDateInToday(day) {
                NSColor.labelColor.setStroke()
                box.lineWidth = 2
                box.stroke()
            }
            text("\(i + 1)", NSPoint(x: r.minX + 6, y: r.minY + 4), 11, level >= 3 ? .white : .secondaryLabelColor, centered: false)
            if minutes[i] > 0 {
                text(hm(minutes[i]), NSPoint(x: r.midX, y: r.maxY - 20), 12, level >= 3 ? .white : .labelColor, weight: .semibold)
            }
        }

        // Legend: the six shades and where each starts.
        let ly = top + 20 + 6 * (cell.height + gap) + 6
        text("Tomato intensity (minutes per day)", NSPoint(x: bounds.midX, y: ly), 11, .secondaryLabelColor)
        for (i, step) in Self.steps.enumerated() {
            let r = NSRect(x: bounds.midX - 140 + CGFloat(i) * 48, y: ly + 20, width: 40, height: 14)
            (i == 0 ? NSColor.quaternaryLabelColor : NSColor.systemRed.withAlphaComponent(Self.alphas[i])).setFill()
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            text(step.label, NSPoint(x: r.midX, y: r.maxY + 3), 10, .secondaryLabelColor)
        }

        // Group tab: this week's ranking (week start per this Mac's settings), "You" for me.
        var ranked: [String] = []
        if var g {
            g.members = g.members.map { var m = $0; if m.uid == me { m.name = "You" }; return m }
            let ry = ly + 62
            text("This week", NSPoint(x: bounds.midX, y: ry), 13, weight: .semibold)
            for (i, row) in weeklyRanking(g, now: Date(), calendar: cal).enumerated() {
                let y = ry + 24 + CGFloat(i) * 22
                let place = i < 3 ? ["🥇", "🥈", "🥉"][i] : "\(i + 1)."
                text("\(place)  \(row.name)", NSPoint(x: bounds.midX - 120, y: y), 13, centered: false)
                text(hm(row.minutes), NSPoint(x: bounds.midX + 120, y: y), 13, weight: .semibold, right: true)
                ranked.append("\(i + 1). \(row.name) \(hm(row.minutes))")
            }
        }

        let busy = zip(days, minutes).filter { $0.1 > 0 }.map { "\(cal.component(.day, from: $0.0)): \(hm($0.1))" }
        setAccessibilityLabel("\(g.map { "\($0.name), " } ?? "")\(title), \(total). "
            + (busy.isEmpty ? "No tomato minutes yet." : busy.joined(separator: ", "))
            + (ranked.isEmpty ? "" : ". This week: " + ranked.joined(separator: ", ")))
    }
}

func tomato(_ color: NSColor, size s: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: s * 0.06, y: s * 0.04, width: s * 0.88, height: s * 0.76)).fill()
        NSColor(srgbRed: 0.10, green: 0.45, blue: 0.15, alpha: 1).setFill()  // leaf
        NSBezierPath(ovalIn: NSRect(x: s * 0.30, y: s * 0.68, width: s * 0.40, height: s * 0.22)).fill()
        NSColor.white.withAlphaComponent(0.6).setFill()  // shine
        NSBezierPath(ovalIn: NSRect(x: s * 0.22, y: s * 0.42, width: s * 0.16, height: s * 0.16)).fill()
        return true
    }
}

// Non-activating panel: takes keyboard focus (Return picks the default button) without
// needing macOS to bring this menu-bar app to the front, which it may refuse.
final class OverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }  // borderless windows refuse key by default
}

@MainActor final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let toggleItem = NSMenuItem(title: "Start", action: #selector(toggle), keyEquivalent: "")
    let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
    let todayItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")  // no action = shown as info
    var lastCount = Date()  // when focus time was last added to today's tally
    let calendarView = CalendarView()
    var calendarWindow: NSWindow?
    var tierItems: [NSMenuItem] = []
    let customItem = NSMenuItem(title: "Custom tomato…", action: #selector(customTomato), keyEquivalent: "")
    var tierIndex = min(UserDefaults.standard.object(forKey: "tier") as? Int ?? 1, tiers.count - 1)
    var custom: Tier?  // typed-in length; picking a tier clears it
    var tier: Tier { group.tier ?? custom ?? tiers[tierIndex] }
    var onBreak = false
    var autoNext = false  // start the next focus session when this break ends
    var focused = 0.0   // minutes in this focus session, "1 more minute"s included
    var left = 0.0      // seconds remaining while paused
    var end: Date?      // set while running; wall-clock, so sleep doesn't drift it
    var timer: Timer?
    var overlays: [NSWindow] = []
    var groupsOn = false  // Firebase configured (plist bundled, or --emulator)
    var countdown: Countdown?
    var rest: RestCountdown?
    var group = GroupPlay()  // Groups/GroupsUI.swift

    func applicationDidFinishLaunching(_: Notification) {
        groupsOn = configureFirebase()
        if groupsOn { GroupStore.shared.start() }
        if CommandLine.arguments.contains("--smoke") {  // firebase/tools/smoke.sh
            Task { exit(await GroupStore.shared.smoke()) }
            return
        }
        if CommandLine.arguments.contains("--rest-demo") {  // the last minute of a break, then quit
            rest = RestCountdown(endAt: Date() + Double(restCountdownSeconds), last: 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(restCountdownSeconds + 2)) { exit(0) }
            return
        }
        if CommandLine.arguments.contains("--countdown-demo") {  // look at the three countdown screens, then quit
            for (i, mode) in [CountdownMode.invite, .autoJoin, .starter].enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 13) {
                    self.countdown?.close()
                    self.countdown = Countdown(title: "Mina started a 🍅 Red tomato · 25 min", mode: mode,
                                               startAt: Date() + 10, onJoin: {}, onSkip: {}, onCancel: {})
                    self.countdown?.setJoinedNames(["Mina", "Alex"], waiting: ["Jun"])
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 39) { exit(0) }
            return
        }
        item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        item.button?.imagePosition = .imageLeft
        let menu = NSMenu()
        todayItem.image = tomato(tiers[1].color, size: 16)
        menu.addItem(todayItem)
        menu.addItem(NSMenuItem(title: "Tomato Calendar…", action: #selector(showCalendar), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(toggleItem)
        menu.addItem(NSMenuItem(title: "Reset", action: #selector(resetTapped), keyEquivalent: ""))
        menu.addItem(.separator())
        for (i, t) in tiers.enumerated() {
            let mi = NSMenuItem(title: "\(t.name) tomato · \(Int(t.minutes)) min", action: #selector(pickTier), keyEquivalent: "")
            mi.tag = i
            mi.image = tomato(t.color, size: 16)
            tierItems.append(mi)
            menu.addItem(mi)
        }
        menu.addItem(customItem)
        menu.addItem(.separator())
        menu.addItem(loginItem)
        menu.items.forEach { $0.target = self }
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        item.menu = menu
        reset()
        NotificationCenter.default.addObserver(self, selector: #selector(cloudChanged),
                                               name: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: cloud)
        cloud.synchronize()
        pushToCloud()
        if groupsOn { startGroups() }
    }

    // Another Mac's minutes arrived (may be posted off the main thread).
    @objc func cloudChanged() {
        DispatchQueue.main.async { self.render() }
    }

    func applicationWillTerminate(_: Notification) {
        countFocus()
        pushToCloud()
        publishMinutes()
        cloud.synchronize()
    }

    func menuWillOpen(_: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        rebuildGroupMenu()  // fresh "min left"
    }

    @objc func showCalendar() {
        if calendarWindow == nil {
            let w = NSWindow(contentRect: calendarView.frame, styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "Tomato Calendar"
            w.contentView = calendarView
            w.isReleasedWhenClosed = false
            w.center()
            calendarWindow = w
        }
        if groupsOn { calendarView.setGroups(store.groups, me: store.uid) }
        calendarView.month = Date()
        calendarView.needsDisplay = true
        NSApp.activate()
        calendarWindow?.makeKeyAndOrderFront(nil)
        calendarWindow?.orderFrontRegardless()  // in case macOS declines to bring this menu-bar app forward
    }

    @objc func toggleLogin() {
        let login = SMAppService.mainApp
        do {
            try login.status == .enabled ? login.unregister() : login.register()
        } catch {
            SMAppService.openSystemSettingsLoginItems()  // e.g. needs approval there
        }
    }

    // Adds focus time since the last count to today's tally. A gap over 5 s means the Mac slept: not counted.
    func countFocus() {
        guard !onBreak, let end else { return }
        let gap = min(Date(), end).timeIntervalSince(lastCount)
        lastCount = Date()
        guard gap > 0, gap < 5 else { return }
        var days = localTally()
        days[dayKey(), default: 0] += gap * 60 / unit
        UserDefaults.standard.set(days, forKey: statsKey)
    }

    func run(_ seconds: Double) {
        left = seconds
        end = Date() + seconds
        lastCount = Date()
        timer?.invalidate()
        timer = Timer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer!, forMode: .common)  // .common keeps it ticking while the menu is open
        render()
    }

    func stop() {
        timer?.invalidate()
        end = nil
        pushToCloud()  // on pause, finish and reset; not every second
        publishMinutes()
    }

    @objc func toggle() {
        leaveGroupTomato()  // Pause takes only you out of a group tomato
        guard let end else { return run(left) }
        countFocus()
        left = max(0, end.timeIntervalSinceNow)
        stop()
        render()
    }

    @objc func tick() {
        countFocus()
        guard let end, end.timeIntervalSinceNow <= 0 else { return render() }
        stop()
        left = 0
        if onBreak {
            NSSound(named: "Hero")?.play()
            let next = autoNext
            reset()
            if next { run(left) }
        } else {
            NSSound(named: "Glass")?.play()
            render()
            showOverlay()
        }
    }

    @objc func reset() {
        countFocus()
        stop()
        closeOverlay()
        onBreak = false
        autoNext = false
        group.tier = nil
        focused = tier.minutes
        left = tier.minutes * unit
        render()
    }

    @objc func pickTier(_ sender: NSMenuItem) {
        leaveGroupTomato()
        tierIndex = sender.tag
        UserDefaults.standard.set(tierIndex, forKey: "tier")
        custom = nil
        reset()
    }

    // Asks for 1–60 whole minutes, then starts right away. The length repeats after "break, then next session".
    @objc func customTomato() {
        let limit = Int(maxFocusMinutes)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "Minutes, 1 to \(limit)"
        if let custom { field.stringValue = "\(Int(custom.minutes))" }
        let alert = NSAlert()
        alert.messageText = "Custom tomato"
        alert.informativeText = "How many minutes?"
        alert.accessoryView = field
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        while alert.runModal() == .alertFirstButtonReturn {
            guard let m = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), (1...limit).contains(m) else {
                alert.informativeText = "Type a whole number from 1 to \(limit)."
                continue
            }
            leaveGroupTomato()
            // the tomato's color is the biggest tier it reaches: 30 min = red, 50 = golden
            custom = Tier(name: "\(m)-min", minutes: Double(m),
                          color: tiers.last { $0.minutes <= Double(m) }?.color ?? tiers[0].color)
            reset()
            run(left)
            return
        }
    }

    @objc func break5ThenNext() { startBreak(5, thenNext: true) }
    @objc func break10ThenNext() { startBreak(10, thenNext: true) }
    @objc func break5() { startBreak(5) }
    @objc func break10() { startBreak(10) }

    func startBreak(_ minutes: Double, thenNext: Bool = false) {
        leaveGroupTomato()  // the solo buttons on the red screen
        closeOverlay()
        onBreak = true
        autoNext = thenNext
        run(minutes * unit)
    }

    @objc func oneMore() {
        leaveGroupTomato()
        closeOverlay()
        focused += 1
        run(unit)
    }

    func render() {
        let secs = max(0, Int((end?.timeIntervalSinceNow ?? left).rounded(.up)))
        item.button?.image = onBreak
            ? NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "Break")
            : tomato(tier.color, size: 16)
        statusTitle(String(format: " %d:%02d", secs / 60, secs % 60))
        toggleItem.title = end == nil ? "Start" : "Pause"
        todayItem.title = todayText()
        if calendarWindow?.isVisible == true { calendarView.needsDisplay = true }  // keep today's square live
        tierItems.forEach { $0.state = custom == nil && $0.tag == tierIndex ? .on : .off }
        customItem.state = custom == nil ? .off : .on
        customItem.title = custom.map { "Custom tomato · \(Int($0.minutes)) min…" } ?? "Custom tomato…"
        customItem.image = tomato(custom?.color ?? .systemGray, size: 16)
        publishStatus()
        updateRestCountdown()
    }

    // The last minute of a break that starts the next tomato counts down on screen (RestCountdown).
    func updateRestCountdown() {
        let last = group.gid != nil ? countdownSeconds + 1 : 1
        if onBreak, autoNext || group.gid != nil, let end, end.timeIntervalSinceNow <= Double(restCountdownSeconds),
           end.timeIntervalSinceNow > Double(last - 1) {
            if rest?.endAt != end { rest?.close(); rest = RestCountdown(endAt: end, last: last) }
        } else {
            rest?.close()
            rest = nil
        }
    }

    // Pulsing red layer over every screen (above full-screen apps and the menu bar) until a button is picked.
    func showOverlay() {
        closeOverlay()
        let canExtend = focused + 1 <= maxFocusMinutes
        overlays = NSScreen.screens.map { screen in
            let w = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
            w.hidesOnDeactivate = false
            w.setFrame(screen.frame, display: false)
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.isOpaque = false
            w.backgroundColor = .clear
            w.isReleasedWhenClosed = false
            let content = w.contentView!

            let glow = NSView(frame: content.bounds)
            glow.autoresizingMask = [.width, .height]
            glow.wantsLayer = true
            glow.layer?.backgroundColor = NSColor.systemRed.cgColor
            glow.layer?.opacity = 0.45
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                // slow fade, well under the 3-flashes-per-second seizure threshold
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 0.2
                pulse.toValue = 0.6
                pulse.duration = 0.8
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                glow.layer?.add(pulse, forKey: "pulse")
            }

            let title = NSTextField(labelWithString: "\(tier.name) tomato done!")
            title.font = .boldSystemFont(ofSize: 40)
            title.textColor = .white
            let sub = NSTextField(labelWithString: "You focused \(Int(focused)) min · \(todayText())")
            sub.font = .systemFont(ofSize: 20)
            sub.textColor = .white
            // default button (Return): the group break after a group tomato, else 5 min break then next
            let inGroup = group.gid != nil
            let next = button("5 min break, then next session", #selector(break5ThenNext),
                              color: inGroup ? NSColor(white: 1, alpha: 0.2) : .controlAccentColor)
            if !inGroup { next.keyEquivalent = "\r" }
            var others = [button("5 min break", #selector(break5)), button("10 min break", #selector(break10))]
            if canExtend { others.append(button("1 more minute", #selector(oneMore))) }
            let done = button("End session", #selector(resetTapped))  // no break: back to a fresh tomato, not started
            done.keyEquivalent = "\u{1b}"  // Esc
            others.append(done)
            let row1 = NSStackView(views: [next, button("10 min break, then next session", #selector(break10ThenNext))])
            let row2 = NSStackView(views: others)
            [row1, row2].forEach { $0.spacing = 16 }
            var rows = [row1, row2]
            if inGroup {
                let together = button("10 min break, then next group tomato", #selector(groupBreak), color: .controlAccentColor)
                together.keyEquivalent = "\r"
                rows.insert(NSStackView(views: [together]), at: 0)
            }
            let row = NSStackView(views: rows)
            row.orientation = .vertical
            row.spacing = 12

            let card = NSStackView(views: [NSImageView(image: tomato(tier.color, size: 110)), title, sub, row])
            card.orientation = .vertical
            card.spacing = 18
            card.edgeInsets = NSEdgeInsets(top: 36, left: 56, bottom: 36, right: 56)
            card.wantsLayer = true
            card.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.88).cgColor
            card.layer?.cornerRadius = 28
            card.translatesAutoresizingMaskIntoConstraints = false

            content.addSubview(glow)
            content.addSubview(card)
            NSLayoutConstraint.activate([
                card.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                card.centerYAnchor.constraint(equalTo: content.centerYAnchor),
                card.widthAnchor.constraint(equalTo: row.widthAnchor, constant: 112),  // side padding
            ])
            w.orderFrontRegardless()
            return w
        }
        overlays.first?.makeKey()  // first screen = the one with the menu bar
    }

    func closeOverlay() {
        overlays.forEach { $0.orderOut(nil) }
        overlays = []
    }

    // Self-drawn pill buttons: system buttons look disabled because this menu-bar app is never frontmost.
    func button(_ title: String, _ action: Selector, color: NSColor = NSColor(white: 1, alpha: 0.2)) -> NSButton {
        pillButton(title, target: self, action: action, color: color)
    }
}

// Self-drawn pill buttons for the red screen and the group countdown.
func pillButton(_ title: String, target: AnyObject, action: Selector, color: NSColor = NSColor(white: 1, alpha: 0.2)) -> NSButton {
    let b = NSButton(title: title, target: target, action: action)
    b.isBordered = false
    b.wantsLayer = true
    b.layer?.backgroundColor = color.cgColor
    b.layer?.cornerRadius = 12
    b.attributedTitle = NSAttributedString(string: title, attributes: [
        .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 16, weight: .semibold)])
    NSLayoutConstraint.activate([
        b.heightAnchor.constraint(equalToConstant: 44),
        b.widthAnchor.constraint(equalToConstant: b.intrinsicContentSize.width + 40),
    ])
    return b
}

MainActor.assumeIsolated {  // top-level code runs on the main thread
    let app = NSApplication.shared
    let delegate = App()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
    app.run()
}
