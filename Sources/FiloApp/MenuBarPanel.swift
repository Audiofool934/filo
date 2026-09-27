import AppKit
import SwiftUI

/// A reusable card with its own rounded outline, without NSPopover's arrow chrome.
final class MenuBarPanel: NSPanel {
    var onDismiss: (() -> Void)?
    private var outsideClickMonitor: Any?

    init(content: FiloView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: FiloView.width, height: FiloView.height),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        let host = NSHostingController(rootView: content)
        host.sizingOptions = []
        contentViewController = host
        // Installing a hosting controller adopts its initial zero-sized view bounds.
        setContentSize(NSSize(width: FiloView.width, height: FiloView.height))
        title = "filo"
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show(below button: NSStatusBarButton) {
        guard let anchorWindow = button.window, let screen = anchorWindow.screen else { return }
        let anchor = anchorWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let available = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let x = min(max(anchor.midX - frame.width / 2, available.minX), available.maxX - frame.width)
        let y = max(available.minY, min(anchor.minY - 8, available.maxY) - frame.height)
        let scale = screen.backingScaleFactor
        setFrameOrigin(NSPoint(x: (x * scale).rounded() / scale, y: (y * scale).rounded() / scale))
        makeKeyAndOrderFront(nil)
        // Global monitors receive only other applications' events, leaving our menus alone.
        if outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                self?.dismiss()
            }
        }
    }

    func dismiss() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        guard isVisible else { return }
        orderOut(nil)
        onDismiss?()
    }

    override func cancelOperation(_ sender: Any?) { dismiss() }
    override func performClose(_ sender: Any?) { dismiss() }
}

enum MenuBarIcon {
    /// The curved f from the app icon, simplified for a small monochrome template.
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let stem = NSBezierPath()
            stem.move(to: NSPoint(x: 4, y: 2))
            stem.curve(to: NSPoint(x: 8.5, y: 7), controlPoint1: NSPoint(x: 7.2, y: 2), controlPoint2: NSPoint(x: 8.5, y: 3.7))
            stem.line(to: NSPoint(x: 8.5, y: 12))
            stem.curve(to: NSPoint(x: 14, y: 15.1), controlPoint1: NSPoint(x: 8.5, y: 15.4), controlPoint2: NSPoint(x: 11.1, y: 16.4))
            stem.lineWidth = 1.8; stem.lineCapStyle = .round; stem.stroke()
            let cross = NSBezierPath()
            cross.move(to: NSPoint(x: 4.5, y: 9.1)); cross.line(to: NSPoint(x: 13.5, y: 9.1))
            cross.lineWidth = 1.8; cross.lineCapStyle = .round; cross.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "filo"
        return image
    }
}
