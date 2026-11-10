// The countdown screens. The 10-second countdown before a group tomato, on every screen: the workspace stays visible under a light
// tint, a giant number fades out while growing each second, and a dark bar at the bottom holds the buttons.
// Purely visual: the caller starts the tomato at `startAt`.
import AppKit

final class Countdown: NSObject {
    private let startAt: Date
    private let onJoin: () -> Void, onSkip: () -> Void, onCancel: () -> Void
    private var joined: Bool  // shows "Go" at 0 only for people who are in
    private var windows: [NSWindow] = []
    private var numbers: [CATextLayer] = []
    private var choiceButtons: [NSButton] = []
    private var joinedLabels: [NSTextField] = []
    private var timer: Timer?
    private var shown = ""

    // `note`: why an auto-join countdown asks nothing.
    init(title: String, mode: CountdownMode, startAt: Date, note: String = "Auto-join is on", onJoin: @escaping () -> Void,
         onSkip: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.startAt = startAt
        self.onJoin = onJoin
        self.onSkip = onSkip
        self.onCancel = onCancel
        joined = mode != .invite
        super.init()
        windows = NSScreen.screens.map { window(on: $0, title: title, mode: mode, note: note) }
        windows.forEach { $0.orderFrontRegardless() }
        windows.first?.makeKey()  // first screen has the menu bar; Return / Esc go here
        timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        tick()
    }

    func setJoinedNames(_ names: [String], waiting: [String]) {
        let text = (names.map { "\($0) ✓" } + waiting.map { "\($0) …" }).joined(separator: " · ")
        joinedLabels.forEach { $0.stringValue = text }
    }

    func close() {
        timer?.invalidate()
        timer = nil
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }

    @objc private func join() {
        joined = true
        choiceButtons.forEach { $0.isHidden = true }
        onJoin()
    }

    @objc private func skip() { close(); onSkip() }
    @objc private func cancel() { close(); onCancel() }

    private func tick() {
        let left = startAt.timeIntervalSinceNow
        if left <= (joined ? -1 : 0) { return close() }  // "Go" stays up for a second, only if you're in
        let text = left > 0 ? String(Int(left.rounded(.up))) : "Go"
        guard text != shown else { return }
        shown = text
        numbers.forEach { pulse($0, text) }
    }

    private func window(on screen: NSScreen, title: String, mode: CountdownMode, note: String) -> NSWindow {
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
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        let size = screen.frame.size

        let number = numberLayer(screen)
        number.fontSize = size.height * bigNumber
        let lineHeight = number.fontSize * 1.2
        number.frame = CGRect(x: 0, y: (size.height - lineHeight) / 2 + size.height * 0.04, width: size.width, height: lineHeight)
        content.layer?.addSublayer(number)
        numbers.append(number)

        var views: [NSView] = [label(title, 17, .semibold, alpha: 1)]
        switch mode {
        case .invite:
            let join = pillButton("Join ⏎", target: self, action: #selector(join), color: .controlAccentColor)
            join.keyEquivalent = "\r"
            let skip = pillButton("Skip", target: self, action: #selector(skip))
            skip.keyEquivalent = "\u{1b}"
            choiceButtons += [join, skip]
            views += [join, skip]
        case .autoJoin:
            let skip = pillButton("Skip this one  esc", target: self, action: #selector(skip))
            skip.keyEquivalent = "\u{1b}"
            views += [skip, label(note, 14, .regular, alpha: 0.7)]
        case .starter:
            let cancel = pillButton("Cancel", target: self, action: #selector(cancel))
            cancel.keyEquivalent = "\u{1b}"
            views.append(cancel)
        }
        let joinedLabel = label("", 14, .regular, alpha: 0.75)
        joinedLabels.append(joinedLabel)
        views.append(joinedLabel)

        let bar = NSStackView(views: views)
        bar.spacing = 16
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 28, bottom: 10, right: 28)
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        bar.layer?.cornerRadius = 32
        bar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -size.height * 0.05),
        ])
        return w
    }

    private func label(_ text: String, _ size: CGFloat, _ weight: NSFont.Weight, alpha: CGFloat) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = NSColor.white.withAlphaComponent(alpha)
        return l
    }
}

// How long the end-of-break countdown runs. The user liked 60 (2026-11-10) but may change it after customer
// feedback: e.g. 30, or the whole break counting down on screen.
let restCountdownSeconds = 60

let bigNumber: CGFloat = 0.62  // font size / screen height; the glyphs come out about 70% of the screen height

func numberLayer(_ screen: NSScreen) -> CATextLayer {
    let number = CATextLayer()
    number.font = NSFont.systemFont(ofSize: 10, weight: .heavy)
    number.alignmentMode = .center
    number.foregroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
    number.contentsScale = screen.backingScaleFactor
    number.shadowColor = NSColor.black.cgColor
    number.shadowOpacity = 0.45
    number.shadowRadius = 24
    number.shadowOffset = CGSize(width: 0, height: -6)
    number.opacity = 0
    return number
}

// One second of a countdown: the number fades out while it grows (fade only under Reduce Motion).
func pulse(_ layer: CATextLayer, _ text: String) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.string = text
    layer.opacity = 0  // where each second's animation ends
    CATransaction.commit()
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 1
    fade.toValue = 0
    var parts: [CAAnimation] = [fade]
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.85
        grow.toValue = 1.15
        parts.append(grow)
    }
    let group = CAAnimationGroup()
    group.animations = parts
    group.duration = 1
    group.timingFunction = CAMediaTimingFunction(name: .easeIn)
    layer.add(group, forKey: "pulse")
}

// The last minute of a break that starts the next tomato: restCountdownSeconds…`last`, each number fading out while it grows,
// starting small in the top-right corner (near the menu-bar timer) and getting bigger and closer to the
// middle each second, up to the group countdown's size. No tint, clicks pass through: it's still your break.
final class RestCountdown: NSObject {
    let endAt: Date
    private let last: Int  // 1 solo; 11 in a group break, where the group's own 10-second countdown takes over
    private var windows: [NSWindow] = []
    private var numbers: [(layer: CATextLayer, size: CGSize)] = []
    private var timer: Timer?
    private var shown = 0

    init(endAt: Date, last: Int) {
        self.endAt = endAt
        self.last = last
        super.init()
        windows = NSScreen.screens.map { screen in
            let w = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
            w.hidesOnDeactivate = false
            w.setFrame(screen.frame, display: false)
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.isOpaque = false
            w.backgroundColor = .clear
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            w.contentView!.wantsLayer = true
            let number = numberLayer(screen)
            w.contentView!.layer?.addSublayer(number)
            numbers.append((number, screen.frame.size))
            w.orderFrontRegardless()
            return w
        }
        timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        tick()
    }

    func close() {
        timer?.invalidate()
        timer = nil
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }

    private func tick() {
        let n = Int(endAt.timeIntervalSinceNow.rounded(.up))
        if n < last { return close() }
        guard n != shown, n <= restCountdownSeconds else { return }
        shown = n
        let p = min(1, max(0, CGFloat(restCountdownSeconds - n) / CGFloat(restCountdownSeconds - last)))
        let e = p * p  // small for a long while, then grows faster as the start nears
        for (layer, size) in numbers {
            let font = size.height * (0.07 + (bigNumber - 0.07) * e)
            let box = CGSize(width: font * 1.5, height: font * 1.2)
            let corner = CGPoint(x: size.width - box.width / 2 - size.height * 0.04,
                                 y: size.height - box.height / 2 - size.height * 0.06)
            let middle = CGPoint(x: size.width / 2, y: size.height / 2 + size.height * 0.04)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.fontSize = font
            layer.frame = CGRect(x: corner.x + (middle.x - corner.x) * e - box.width / 2,
                                 y: corner.y + (middle.y - corner.y) * e - box.height / 2,
                                 width: box.width, height: box.height)
            CATransaction.commit()
            pulse(layer, String(n))
        }
    }
}
