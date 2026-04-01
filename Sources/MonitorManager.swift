import Foundation
import CoreGraphics
import AppKit
import ApplicationServices

struct Monitor {
    let id: Int
    let name: String
}

enum MonitorTransition: CustomStringConvertible {
    case none
    case move
    case click
    case moveAndClick

    var requiresAction: Bool {
        self != .none
    }

    var appliesFocus: Bool {
        self == .click || self == .moveAndClick
    }

    var description: String {
        switch self {
        case .none: return ".none"
        case .move: return ".move"
        case .click: return ".click"
        case .moveAndClick: return ".moveAndClick"
        }
    }
}

enum MonitorManager {
    static func listMonitors() -> [Monitor] {
        let maxDisplays: UInt32 = 16
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var displayCount: UInt32 = 0
        let err = CGGetActiveDisplayList(maxDisplays, &displays, &displayCount)
        guard err == .success else { return [] }

        var monitors: [Monitor] = []
        for i in 0..<Int(displayCount) {
            let displayID = displays[i]
            let bounds = CGDisplayBounds(displayID)
            let name = screenName(for: displayID)
                ?? "\(Int(bounds.width))x\(Int(bounds.height))"
            monitors.append(Monitor(id: Int(displayID), name: name))
        }
        return monitors
    }

    static func currentMonitor() -> Int? {
        let mouseLocation = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            if screen.frame.contains(mouseLocation) {
                let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
                return screenNumber.map { Int($0) }
            }
        }
        return nil
    }

    static func focusedMonitor() -> Int? {
        if let result = focusedMonitorViaCGWindowList() {
            return result
        }
        return focusedMonitorViaAccessibility()
    }

    private static func focusedMonitorViaCGWindowList() -> Int? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        let pid = frontApp.processIdentifier

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        for windowInfo in windowList {
            guard let windowPID = windowInfo[kCGWindowOwnerPID as String] as? Int32,
                  windowPID == pid,
                  let layer = windowInfo[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let boundsDict = windowInfo[kCGWindowBounds as String] as? NSDictionary else {
                continue
            }

            var rect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDict as CFDictionary, &rect) else {
                continue
            }

            return monitorContaining(point: CGPoint(x: rect.midX, y: rect.midY))
        }

        return nil
    }

    private static func focusedMonitorViaAccessibility() -> Int? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedAppValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &focusedAppValue
        ) == .success,
        let focusedAppValue,
        CFGetTypeID(focusedAppValue) == AXUIElementGetTypeID() else {
            return nil
        }

        let appElement = unsafeBitCast(focusedAppValue, to: AXUIElement.self)
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var windowValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                appElement,
                attribute as CFString,
                &windowValue
            ) == .success,
            let windowValue,
            CFGetTypeID(windowValue) == AXUIElementGetTypeID() else {
                continue
            }

            let windowElement = unsafeBitCast(windowValue, to: AXUIElement.self)
            if let frame = windowFrame(for: windowElement) {
                return monitorContaining(point: CGPoint(x: frame.midX, y: frame.midY))
            }
        }

        return nil
    }

    private static func windowFrame(for element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?

        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
        AXUIElementCopyAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            &sizeValue
        ) == .success,
        let positionValue,
        let sizeValue,
        CFGetTypeID(positionValue) == AXValueGetTypeID(),
        CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        let positionAXValue = unsafeBitCast(positionValue, to: AXValue.self)
        let sizeAXValue = unsafeBitCast(sizeValue, to: AXValue.self)
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetType(positionAXValue) == .cgPoint,
              AXValueGetType(sizeAXValue) == .cgSize,
              AXValueGetValue(positionAXValue, .cgPoint, &position),
              AXValueGetValue(sizeAXValue, .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    static func transition(
        to id: Int,
        cursorMonitor: Int?
    ) -> MonitorTransition {
        let hasCursor = cursorMonitor == id

        if hasCursor {
            let axFocused = focusedMonitor() == id
            return axFocused ? .none : .click
        } else {
            return .moveAndClick
        }
    }

    static func focusMonitor(_ id: Int, transition: MonitorTransition, debug: Bool = false) {
        guard transition.requiresAction else { return }

        let displayID = CGDirectDisplayID(id)
        let bounds = CGDisplayBounds(displayID)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let focusPoint = topWindowClickPoint(onMonitor: id) ?? center

        if transition == .move || transition == .moveAndClick {
            CGWarpMouseCursorPosition(focusPoint)
        }

        if transition.appliesFocus {
            let clickPos = transition == .click
                ? CGEvent(source: nil)?.location ?? focusPoint
                : focusPoint
            let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: clickPos, mouseButton: .left)
            let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: clickPos, mouseButton: .left)

            mouseDown?.post(tap: .cghidEventTap)
            mouseUp?.post(tap: .cghidEventTap)
        }
    }

    private static func topWindowClickPoint(onMonitor monitorID: Int) -> CGPoint? {
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
                  let boundsDict = windowInfo[kCGWindowBounds as String] as? NSDictionary else {
                continue
            }

            var rect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDict as CFDictionary, &rect),
                  rect.width > 80,
                  rect.height > 60 else {
                continue
            }

            let midPoint = CGPoint(x: rect.midX, y: rect.midY)
            guard monitorContaining(point: midPoint) == monitorID else {
                continue
            }

            let titleBarY = max(rect.minY + 24, rect.maxY - min(32, rect.height * 0.12))
            return CGPoint(x: rect.midX, y: titleBarY)
        }

        return nil
    }

    private static func monitorContaining(point: CGPoint) -> Int? {
        let maxDisplays: UInt32 = 16
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(maxDisplays, &displays, &displayCount) == .success else {
            return nil
        }

        for index in 0..<Int(displayCount) {
            let displayID = displays[index]
            if CGDisplayBounds(displayID).contains(point) {
                return Int(displayID)
            }
        }

        return nil
    }

    private static func screenName(for displayID: CGDirectDisplayID) -> String? {
        for screen in NSScreen.screens {
            let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            if screenNumber == displayID {
                return screen.localizedName
            }
        }
        return nil
    }
}
