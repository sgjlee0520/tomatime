// Plain backdrop for App Store screenshots. Covers wallpaper, desktop icons, windows and the Dock,
// but not the menu bar. Changes no settings. Click it to close; it also closes after 10 minutes.
// Usage: swift tools/backdrop.swift
import AppKit

final class Backdrop: NSView {
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
    override func mouseDown(with _: NSEvent) { NSApp.terminate(nil) }

    override func draw(_: NSRect) {
        NSGradient(colors: [NSColor(srgbRed: 0.99, green: 0.95, blue: 0.89, alpha: 1),
                            NSColor(srgbRed: 0.95, green: 0.84, blue: 0.75, alpha: 1)])!
            .draw(in: bounds, angle: -60)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let windows = NSScreen.screens.map { screen in
    let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
    w.setFrame(screen.frame, display: false)
    w.level = NSWindow.Level(rawValue: 21)  // above the Dock (20), below the menu bar (24)
    w.collectionBehavior = [.canJoinAllSpaces, .stationary]
    w.contentView = Backdrop()
    w.orderFrontRegardless()
    return w
}
DispatchQueue.main.asyncAfter(deadline: .now() + 600) { NSApp.terminate(nil) }
app.run()
