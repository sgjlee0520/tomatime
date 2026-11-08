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

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let toggleItem = NSMenuItem(title: "Start", action: #selector(toggle), keyEquivalent: "")
    let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
    var tierItems: [NSMenuItem] = []
    var tierIndex = min(UserDefaults.standard.object(forKey: "tier") as? Int ?? 1, tiers.count - 1)
    var tier: Tier { tiers[tierIndex] }
    var onBreak = false
    var autoNext = false  // start the next focus session when this break ends
    var focused = 0.0   // minutes in this focus session, "1 more minute"s included
    var left = 0.0      // seconds remaining while paused
    var end: Date?      // set while running; wall-clock, so sleep doesn't drift it
    var timer: Timer?
    var overlays: [NSWindow] = []

    func applicationDidFinishLaunching(_: Notification) {
        item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        item.button?.imagePosition = .imageLeft
        let menu = NSMenu()
        menu.addItem(toggleItem)
        menu.addItem(NSMenuItem(title: "Reset", action: #selector(reset), keyEquivalent: ""))
        menu.addItem(.separator())
        for (i, t) in tiers.enumerated() {
            let mi = NSMenuItem(title: "\(t.name) tomato · \(Int(t.minutes)) min", action: #selector(pickTier), keyEquivalent: "")
            mi.tag = i
            mi.image = tomato(t.color, size: 16)
            tierItems.append(mi)
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        menu.addItem(loginItem)
        menu.items.forEach { $0.target = self }
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        item.menu = menu
        reset()
    }

    func menuWillOpen(_: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc func toggleLogin() {
        let login = SMAppService.mainApp
        do {
            try login.status == .enabled ? login.unregister() : login.register()
        } catch {
            SMAppService.openSystemSettingsLoginItems()  // e.g. needs approval there
        }
    }

    func run(_ seconds: Double) {
        left = seconds
        end = Date() + seconds
        timer?.invalidate()
        timer = Timer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer!, forMode: .common)  // .common keeps it ticking while the menu is open
        render()
    }

    func stop() {
        timer?.invalidate()
        end = nil
    }

    @objc func toggle() {
        guard let end else { return run(left) }
        left = max(0, end.timeIntervalSinceNow)
        stop()
        render()
    }

    @objc func tick() {
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
        stop()
        closeOverlay()
        onBreak = false
        autoNext = false
        focused = tier.minutes
        left = tier.minutes * unit
        render()
    }

    @objc func pickTier(_ sender: NSMenuItem) {
        tierIndex = sender.tag
        UserDefaults.standard.set(tierIndex, forKey: "tier")
        reset()
    }

    @objc func break5ThenNext() { startBreak(5, thenNext: true) }
    @objc func break5() { startBreak(5) }
    @objc func break10() { startBreak(10) }

    func startBreak(_ minutes: Double, thenNext: Bool = false) {
        closeOverlay()
        onBreak = true
        autoNext = thenNext
        run(minutes * unit)
    }

    @objc func oneMore() {
        closeOverlay()
        focused += 1
        run(unit)
    }

    func render() {
        let secs = max(0, Int((end?.timeIntervalSinceNow ?? left).rounded(.up)))
        item.button?.image = onBreak
            ? NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "Break")
            : tomato(tier.color, size: 16)
        item.button?.title = String(format: " %d:%02d", secs / 60, secs % 60)
        toggleItem.title = end == nil ? "Start" : "Pause"
        tierItems.forEach { $0.state = $0.tag == tierIndex ? .on : .off }
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
            let sub = NSTextField(labelWithString: "You focused \(Int(focused)) min. Take a break.")
            sub.font = .systemFont(ofSize: 20)
            sub.textColor = .white
            let next = button("5 min break, then next session", #selector(break5ThenNext), color: .controlAccentColor)
            next.keyEquivalent = "\r"  // default button; Return picks it
            var buttons = [next, button("5 min break", #selector(break5)), button("10 min break", #selector(break10))]
            if canExtend { buttons.append(button("1 more minute", #selector(oneMore))) }
            let row = NSStackView(views: buttons)
            row.spacing = 16

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
        let b = NSButton(title: title, target: self, action: action)
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
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
app.run()
