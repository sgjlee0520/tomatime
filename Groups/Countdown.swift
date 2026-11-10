// The 10-second countdown before a group tomato, on every screen: the workspace stays visible under a light
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

    private func pulse(_ layer: CATextLayer, _ text: String) {
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

        let number = CATextLayer()
        number.font = NSFont.systemFont(ofSize: 10, weight: .heavy)
        number.fontSize = size.height * 0.62  // the glyphs come out about 70% of the screen height with the line box
        number.alignmentMode = .center
        number.foregroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        number.contentsScale = screen.backingScaleFactor
        number.shadowColor = NSColor.black.cgColor
        number.shadowOpacity = 0.45
        number.shadowRadius = 24
        number.shadowOffset = CGSize(width: 0, height: -6)
        let lineHeight = number.fontSize * 1.2
        number.frame = CGRect(x: 0, y: (size.height - lineHeight) / 2 + size.height * 0.04, width: size.width, height: lineHeight)
        number.opacity = 0
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
