import AppKit

enum WindowHighlight {
    private static let overlayLevel = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
    private static var activeScreenNumber: CGDirectDisplayID?
    private static var backdropWindow: NSWindow?
    private static var borderWindow: NSWindow?

    fileprivate static var borderColor: NSColor = .systemGreen
    fileprivate static var windowFrame: CGRect = .zero

    static func update(windowFrame: CGRect, screen: NSScreen) {
        if NSApp == nil { _ = NSApplication.shared }
        NSApp.setActivationPolicy(.accessory)

        let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        if activeScreenNumber != screenNumber {
            hide()
            activeScreenNumber = screenNumber
        }

        Self.windowFrame = windowFrame
        ensureBackdrop(on: screen)
        ensureBorder(on: screen)

        updateBackdrop(on: screen)
        updateBorder()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
    }

    static func setColor(grabbed: Bool) {
        borderColor = grabbed ? .systemGreen : .systemBlue
        if let view = borderWindow?.contentView as? WindowBorderPanelView {
            view.needsDisplay = true
        }
    }

    static func hide() {
        backdropWindow?.orderOut(nil)
        borderWindow?.orderOut(nil)

        backdropWindow = nil
        borderWindow = nil
        activeScreenNumber = nil
        windowFrame = .zero

        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }

    private static func ensureBackdrop(on screen: NSScreen) {
        guard backdropWindow == nil else { return }
        let window = makeOverlayWindow(frame: screen.frame, screen: screen)
        window.contentView = BackdropCutoutView(frame: NSRect(origin: .zero, size: screen.frame.size))
        window.orderFrontRegardless()
        backdropWindow = window
    }

    private static func ensureBorder(on screen: NSScreen) {
        guard borderWindow == nil else { return }
        let window = makeOverlayWindow(frame: windowFrame, screen: screen)
        window.backgroundColor = .clear
        window.contentView = WindowBorderPanelView(frame: NSRect(origin: .zero, size: windowFrame.size))
        window.orderFrontRegardless()
        borderWindow = window
    }

    private static func updateBackdrop(on screen: NSScreen) {
        guard let backdropWindow else { return }
        backdropWindow.setFrame(screen.frame, display: true)
        if let view = backdropWindow.contentView as? BackdropCutoutView {
            view.frame = NSRect(origin: .zero, size: screen.frame.size)
            view.screenFrame = screen.frame
            view.windowFrame = windowFrame
            view.needsDisplay = true
        }
        backdropWindow.orderFrontRegardless()
    }

    private static func updateBorder() {
        guard let borderWindow else { return }
        borderWindow.setFrame(windowFrame, display: true)
        if let view = borderWindow.contentView as? WindowBorderPanelView {
            view.frame = NSRect(origin: .zero, size: windowFrame.size)
            view.needsDisplay = true
        }
        borderWindow.orderFrontRegardless()
    }

    private static func makeOverlayWindow(frame: CGRect, screen: NSScreen?) -> NSWindow {
        let window = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = overlayLevel
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        return window
    }
}

private final class BackdropCutoutView: NSView {
    var screenFrame: CGRect = .zero
    var windowFrame: CGRect = .zero

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds)
        let hole = NSBezierPath(
            roundedRect: localRect(windowFrame.insetBy(dx: -14, dy: -14)),
            xRadius: 28,
            yRadius: 28
        )
        path.append(hole)
        path.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.38).setFill()
        path.fill()

        let cutoutBorder = NSBezierPath(
            roundedRect: localRect(windowFrame.insetBy(dx: -10, dy: -10)),
            xRadius: 22,
            yRadius: 22
        )
        cutoutBorder.lineWidth = 2.5
        NSColor.white.withAlphaComponent(0.85).setStroke()
        cutoutBorder.stroke()
    }

    private func localRect(_ globalRect: CGRect) -> CGRect {
        CGRect(
            x: globalRect.minX - screenFrame.minX,
            y: globalRect.minY - screenFrame.minY,
            width: globalRect.width,
            height: globalRect.height
        )
    }
}

private final class WindowBorderPanelView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let accent = WindowHighlight.borderColor
        let outer = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 14, yRadius: 14)
        outer.lineWidth = 10
        accent.withAlphaComponent(0.22).setStroke()
        outer.stroke()

        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 5), xRadius: 12, yRadius: 12)
        border.lineWidth = 3
        accent.withAlphaComponent(0.95).setStroke()
        border.stroke()
    }
}
