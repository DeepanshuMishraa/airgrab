import Foundation
import AppKit
import ApplicationServices

enum WindowAction {
    case none
    case move
    case resize
}

final class WindowManager {
    private var grabbedWindow: AXUIElement?
    private var grabStartWindowPosition: CGPoint = .zero
    private var currentWindowPosition: CGPoint = .zero
    private var lastDragHandPosition: CGPoint?
    private var currentTargetMonitorID: Int?

    var currentAction: WindowAction {
        grabbedWindow != nil ? .move : .none
    }

    func grabWindow(onMonitor monitorID: Int, handPosition: CGPoint, gazePosition: CGPoint? = nil) -> Bool {
        guard let screen = screen(forMonitor: monitorID) else {
            return false
        }

        let selectionPosition = gazePosition ?? handPosition
        let targetPoint = screenPoint(for: selectionPosition, in: screen.frame)

        guard let window = window(at: targetPoint, onMonitor: monitorID),
              let position = windowPosition(window) else {
            return false
        }

        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        grabStartWindowPosition = position
        currentWindowPosition = position
        lastDragHandPosition = handPosition
        currentTargetMonitorID = monitorID
        grabbedWindow = window
        updateOverlay(handPosition: handPosition, fallbackScreen: screen)
        return true
    }

    /// Call when switching from pinch to open palm mid-drag so palm-centroid jump does not apply as motion.
    func resetDragAnchor(handPosition: CGPoint) {
        lastDragHandPosition = handPosition
    }

    func moveWindowByHand(handPosition: CGPoint, targetMonitorID: Int?) {
        guard let window = grabbedWindow else {
            return
        }

        if let targetMonitorID, targetMonitorID != currentTargetMonitorID {
            transferGrabbedWindow(toMonitor: targetMonitorID)
        }

        if lastDragHandPosition == nil {
            lastDragHandPosition = handPosition
        }
        guard let lastHand = lastDragHandPosition else { return }
        let deltaNormX = handPosition.x - lastHand.x
        let deltaNormY = handPosition.y - lastHand.y
        lastDragHandPosition = handPosition

        let refFrame = movementReferenceFrame(for: window)
        guard refFrame.width >= 1, refFrame.height >= 1 else { return }

        let moveX = deltaNormX * refFrame.width * 2.0
        let moveY = -deltaNormY * refFrame.height * 2.0
        let raw = CGPoint(
            x: currentWindowPosition.x + moveX,
            y: currentWindowPosition.y + moveY
        )

        let unionVisible = unionVisibleFrames()
        let clamped = clampWindowOrigin(raw, window: window, to: unionVisible)
        setWindowPosition(window, position: clamped)
        currentWindowPosition = clamped

        updateOverlay(handPosition: handPosition)
    }

    private func windowPosition(_ window: AXUIElement) -> CGPoint? {
        var positionValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
        let positionValue,
        CFGetTypeID(positionValue) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeBitCast(positionValue, to: AXValue.self)
        var position = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &position) else {
            return nil
        }
        return position
    }

    func releaseWindow(handPosition _: CGPoint? = nil, targetMonitorID _: Int? = nil) {
        grabbedWindow = nil
        grabStartWindowPosition = .zero
        currentWindowPosition = .zero
        lastDragHandPosition = nil
        currentTargetMonitorID = nil
        WindowHighlight.hide()
    }

    private func windowFrame(_ window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
        let positionValue,
        CFGetTypeID(positionValue) == AXValueGetTypeID() else {
            return nil
        }

        let positionAxValue = unsafeBitCast(positionValue, to: AXValue.self)
        var position = CGPoint.zero
        guard AXValueGetValue(positionAxValue, .cgPoint, &position) else {
            return nil
        }

        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXSizeAttribute as CFString,
            &sizeValue
        ) == .success,
        let sizeValue,
        CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        let sizeAxValue = unsafeBitCast(sizeValue, to: AXValue.self)
        var size = CGSize.zero
        guard AXValueGetValue(sizeAxValue, .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    private func setWindowPosition(_ window: AXUIElement, position: CGPoint) {
        var pos = position
        guard let axValue = AXValueCreate(.cgPoint, &pos) else {
            return
        }

        AXUIElementSetAttributeValue(
            window,
            kAXPositionAttribute as CFString,
            axValue
        )
    }

    private func window(at point: CGPoint, onMonitor monitorID: Int) -> AXUIElement? {
        if let orderedWindow = orderedWindow(at: point, onMonitor: monitorID) {
            return orderedWindow
        }

        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            systemWide,
            Float(point.x),
            Float(point.y),
            &element
        )

        guard result == .success, let element else {
            return nil
        }

        return enclosingWindow(startingAt: element)
    }

    private func orderedWindow(at point: CGPoint, onMonitor monitorID: Int) -> AXUIElement? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        for windowInfo in windowList {
            guard let layer = windowInfo[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let alpha = windowInfo[kCGWindowAlpha as String] as? Double,
                  alpha > 0.01,
                  let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDict = windowInfo[kCGWindowBounds as String] as? NSDictionary else {
                continue
            }

            var rect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDict as CFDictionary, &rect),
                  rect.width > 60,
                  rect.height > 40,
                  rect.contains(point) else {
                continue
            }

            let midpoint = CGPoint(x: rect.midX, y: rect.midY)
            guard monitorContaining(point: midpoint) == monitorID else {
                continue
            }

            if let axWindow = accessibilityWindow(pid: ownerPID, near: rect) {
                return axWindow
            }
        }

        return nil
    }

    private func accessibilityWindow(pid: pid_t, near rect: CGRect) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsValue
        ) == .success,
        let value = windowsValue,
        let windows = value as? [AXUIElement] else {
            return nil
        }

        var bestWindow: AXUIElement?
        var bestScore = CGFloat.infinity

        for window in windows {
            guard let frame = windowFrame(window) else { continue }

            let dx = abs(frame.midX - rect.midX)
            let dy = abs(frame.midY - rect.midY)
            let dw = abs(frame.width - rect.width)
            let dh = abs(frame.height - rect.height)
            let score = dx + dy + (dw + dh) * CGFloat(0.2)

            if score < bestScore {
                bestScore = score
                bestWindow = window
            }
        }

        return bestWindow
    }

    private func enclosingWindow(startingAt element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        var depth = 0

        while let candidate = current, depth < 12 {
            var roleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                candidate,
                kAXRoleAttribute as CFString,
                &roleValue
            ) == .success,
            let role = roleValue as? String,
            role == kAXWindowRole as String {
                return candidate
            }

            var windowValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                candidate,
                kAXWindowAttribute as CFString,
                &windowValue
            ) == .success,
            let windowValue,
            CFGetTypeID(windowValue) == AXUIElementGetTypeID() {
                return unsafeBitCast(windowValue, to: AXUIElement.self)
            }

            var parentValue: CFTypeRef?
            let parentResult = AXUIElementCopyAttributeValue(
                candidate,
                kAXParentAttribute as CFString,
                &parentValue
            )

            if parentResult == .success,
               let parentValue,
               CFGetTypeID(parentValue) == AXUIElementGetTypeID() {
                current = unsafeBitCast(parentValue, to: AXUIElement.self)
            } else {
                current = nil
            }

            depth += 1
        }

        return nil
    }

    private func screen(forMonitor monitorID: Int) -> NSScreen? {
        NSScreen.screens.first { screen in
            let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            return screenNumber.map(Int.init) == monitorID
        }
    }

    private func screenPoint(for handPosition: CGPoint, in frame: CGRect) -> CGPoint {
        let clampedX = min(max(handPosition.x, 0.0), 1.0)
        let clampedY = min(max(handPosition.y, 0.0), 1.0)

        return CGPoint(
            x: frame.minX + clampedX * frame.width,
            y: frame.maxY - clampedY * frame.height
        )
    }

    func monitorContainingGrabbedWindow() -> Int? {
        guard let window = grabbedWindow,
              let frame = windowFrame(window),
              let screen = screenContaining(frame),
              let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }

        return Int(screenNumber)
    }

    private func transferGrabbedWindow(toMonitor monitorID: Int) {
        guard let window = grabbedWindow,
              let frame = windowFrame(window),
              let sourceScreen = screenContaining(frame),
              let targetScreen = screen(forMonitor: monitorID) else {
            return
        }

        let sourceVisible = sourceScreen.visibleFrame
        let targetVisible = targetScreen.visibleFrame
        let availableSourceWidth = max(1, sourceVisible.width - frame.width)
        let availableSourceHeight = max(1, sourceVisible.height - frame.height)

        let relativeX = (frame.minX - sourceVisible.minX) / availableSourceWidth
        let relativeY = (frame.minY - sourceVisible.minY) / availableSourceHeight

        let newPosition = CGPoint(
            x: targetVisible.minX + relativeX * max(1, targetVisible.width - frame.width),
            y: targetVisible.minY + relativeY * max(1, targetVisible.height - frame.height)
        )

        setWindowPosition(window, position: newPosition)
        grabStartWindowPosition = newPosition
        currentWindowPosition = newPosition
        currentTargetMonitorID = monitorID
        lastDragHandPosition = nil
    }

    private func updateOverlay(handPosition _: CGPoint, fallbackScreen: NSScreen? = nil) {
        guard let window = grabbedWindow,
              let frame = windowFrame(window) else {
            return
        }

        let targetScreen = currentTargetMonitorID.flatMap(screen(forMonitor:))
            ?? fallbackScreen
            ?? screenContaining(frame)

        guard let targetScreen else { return }

        WindowHighlight.update(windowFrame: frame, screen: targetScreen)
        WindowHighlight.setColor(grabbed: true)
    }

    private func screenContaining(_ frame: CGRect) -> NSScreen? {
        NSScreen.screens.first { screen in
            screen.frame.intersects(frame)
        } ?? NSScreen.main
    }

    private func monitorContaining(point: CGPoint) -> Int? {
        NSScreen.screens.first {
            $0.frame.contains(point)
        }.flatMap {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map(Int.init)
        }
    }

    private func unionVisibleFrames() -> CGRect {
        NSScreen.screens.reduce(CGRect.null) { partial, screen in
            partial.isNull ? screen.visibleFrame : partial.union(screen.visibleFrame)
        }
    }

    private func movementReferenceFrame(for window: AXUIElement) -> CGRect {
        if let mid = currentTargetMonitorID, let s = screen(forMonitor: mid) {
            return s.frame
        }
        if let f = windowFrame(window), let s = screenContaining(f) {
            return s.frame
        }
        return NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
    }

    private func clampWindowOrigin(_ origin: CGPoint, window: AXUIElement, to unionVisible: CGRect) -> CGPoint {
        guard let fr = windowFrame(window) else { return origin }
        let sz = fr.size
        let minX = unionVisible.minX + 8
        let maxX = unionVisible.maxX - sz.width - 8
        let minY = unionVisible.minY + 8
        let maxY = unionVisible.maxY - sz.height - 8
        return CGPoint(
            x: min(max(origin.x, minX), max(maxX, minX)),
            y: min(max(origin.y, minY), max(maxY, minY))
        )
    }
}
