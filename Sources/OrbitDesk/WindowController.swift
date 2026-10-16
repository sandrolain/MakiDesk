import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum WindowController {
    enum ShortcutAction {
        case leftHalf, rightHalf, topHalf, bottomHalf
        case topLeft, topRight, bottomLeft, bottomRight
        case centerCycle, center, phi, toggleFullScreen, minimize
        case switchWindows, switchWindowsBack, searchWindows
    }

    /// Pixels of a parked window left visible at the screen edge (as small as
    /// macOS allows).
    static let reservedStrip: CGFloat = 6

    struct WindowInfo: Identifiable {
        let id: String
        let title: String
        let appName: String
        let element: AXUIElement
        let frame: CGRect
        let pid: pid_t
        var minimized: Bool = false
        /// Front-to-back stacking order (0 = frontmost). `Int.max` when unknown.
        var zIndex: Int = Int.max
    }

    enum WindowError: LocalizedError {
        case invalidFrame(String)
        case accessibility(AXError, String)

        var errorDescription: String? {
            switch self {
            case let .invalidFrame(attribute):
                return "Unable to read window \(attribute)"
            case let .accessibility(code, operation):
                return "\(operation) failed (\(code.rawValue))"
            }
        }
    }

    static func requestAccessibilityPermission() -> Bool {
        guard !AXIsProcessTrusted() else { return true }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    static func discoverWindows(includeMinimized: Bool = false) -> [WindowInfo] {
        let order = cgWindowOrder()
        let discovered: [WindowInfo] = NSWorkspace.shared.runningApplications
            .filter {
                !$0.isTerminated &&
                $0.activationPolicy == .regular &&
                $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
            }

            .flatMap { app -> [WindowInfo] in
                let appElement = AXUIElementCreateApplication(app.processIdentifier)
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(
                    appElement, kAXWindowsAttribute as CFString, &value
                ) == .success, let windows = value as? [AXUIElement] else {
                    return []
                }

                var usedIDs = Set<String>()
                return windows.enumerated().compactMap { (index, element) -> WindowInfo? in
                    var titleValue: CFTypeRef?
                    let result = AXUIElementCopyAttributeValue(
                        element, kAXTitleAttribute as CFString, &titleValue
                    )
                    let rawTitle = result == .success ? titleValue as? String : nil
                    let title = rawTitle ?? "Untitled window"
                    let minimized = isMinimized(element)
                    if !includeMinimized, minimized { return nil }
                    guard let frame = frame(of: element) ?? (minimized ? .zero : nil) else { return nil }
                    // Skip the untitled full-screen background window (e.g. the
                    // Finder desktop), which is not a real window and cannot move.
                    if !minimized, (rawTitle ?? "").isEmpty, coversScreen(frame) { return nil }
                    let baseIdentifier = attributeString(kAXIdentifierAttribute, of: element)
                        ?? "\(app.processIdentifier)-\(title)-\(index)"
                    var identifier = "\(app.processIdentifier)-\(baseIdentifier)"
                    if usedIDs.contains(identifier) {
                        identifier += "-\(index)"
                    }
                    usedIDs.insert(identifier)
                    return WindowInfo(
                        id: identifier,
                        title: title,
                        appName: app.localizedName ?? "Application",
                        element: element,
                        frame: frame,
                        pid: app.processIdentifier,
                        minimized: minimized,
                        zIndex: stackingIndex(for: app.processIdentifier, frame: frame, in: order)
                    )
                }
            }
        // Front-to-back so array order reflects the real window stack.
        return discovered.sorted {
            $0.zIndex == $1.zIndex ? $0.id < $1.id : $0.zIndex < $1.zIndex
        }
    }

    /// On-screen windows in front-to-back order, matched to Accessibility windows
    /// by owning process and frame so the mini-map can respect the real stack.
    private static func cgWindowOrder() -> [(pid: pid_t, frame: CGRect)] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { entry in
            guard let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else {
                return nil
            }
            return (pid, frame)
        }
    }

    private static func stackingIndex(
        for pid: pid_t,
        frame: CGRect,
        in order: [(pid: pid_t, frame: CGRect)]
    ) -> Int {
        var bestIndex = Int.max
        var bestScore = CGFloat.greatestFiniteMagnitude
        for (index, item) in order.enumerated() where item.pid == pid {
            let score = abs(item.frame.minX - frame.minX)
                + abs(item.frame.minY - frame.minY)
                + abs(item.frame.width - frame.width)
                + abs(item.frame.height - frame.height)
            if score < bestScore {
                bestScore = score
                bestIndex = index
            }
        }
        // Require a reasonably close match; otherwise treat as unknown.
        return bestScore <= 40 ? bestIndex : Int.max
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = point(attribute: kAXPositionAttribute, of: element),
              let size = size(attribute: kAXSizeAttribute, of: element) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    static func frontmostWindow() -> WindowInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &raw
        ) == .success, let raw,
        CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return nil
        }
        let element = raw as! AXUIElement
        guard
        let frame = frame(of: element) else {
            return nil
        }
        var titleValue: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue)
        return WindowInfo(
            id: "\(app.processIdentifier)-frontmost",
            title: titleValue as? String ?? "Untitled window",
            appName: app.localizedName ?? "Application",
            element: element,
            frame: frame,
            pid: app.processIdentifier
        )
    }

    /// Captures a preview image of a window. Needs Screen Recording permission;
    /// returns nil when unavailable.
    static func previewImage(pid: pid_t, frame: CGRect) -> NSImage? {
        guard let id = cgWindowID(pid: pid, frame: frame) else { return nil }
        guard let cgImage = CGWindowListCreateImage(
            .null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution]
        ) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private static func cgWindowID(pid: pid_t, frame: CGRect) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        var bestID: CGWindowID?
        var bestScore = CGFloat.greatestFiniteMagnitude
        for entry in list {
            guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let entryFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  let number = entry[kCGWindowNumber as String] as? NSNumber else { continue }
            let score = abs(entryFrame.minX - frame.minX) + abs(entryFrame.minY - frame.minY)
                + abs(entryFrame.width - frame.width) + abs(entryFrame.height - frame.height)
            if score < bestScore {
                bestScore = score
                bestID = CGWindowID(number.intValue)
            }
        }
        return bestID
    }

    static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    // Cocoa (bottom-left origin) <-> AX (top-left origin); the flip is its own inverse.
    static func flip(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func axVisibleFrame(for screen: NSScreen?) -> CGRect {
        guard let screen else { return CGRect(x: 0, y: 0, width: 1440, height: 900) }
        return flip(screen.visibleFrame)
    }

    private static func coversScreen(_ frame: CGRect) -> Bool {
        let visible = axVisibleFrame(for: NSScreen.main)
        return frame.width >= visible.width - 1 && frame.height >= visible.height - 1
    }

    static func screen(forAXFrame frame: CGRect) -> NSScreen? {
        let cocoa = flip(frame)
        let best = NSScreen.screens.max { lhs, rhs in
            let a = lhs.frame.intersection(cocoa)
            let b = rhs.frame.intersection(cocoa)
            return a.width * a.height < b.width * b.height
        }
        if let best, best.frame.intersects(cocoa) { return best }
        return NSScreen.main
    }

    static func setFrame(_ frame: CGRect, for element: AXUIElement) throws {
        try setPosition(frame.origin, for: element)

        var size = frame.size
        guard let sizeValue = AXValueCreate(.cgSize, &size) else {
            throw WindowError.invalidFrame(kAXSizeAttribute as String)
        }
        try set(sizeValue, attribute: kAXSizeAttribute, on: element, operation: "Set window size")
    }

    /// Moves a window without touching its size, so panning never resizes.
    static func setPosition(_ point: CGPoint, for element: AXUIElement) throws {
        var position = point
        guard let positionValue = AXValueCreate(.cgPoint, &position) else {
            throw WindowError.invalidFrame(kAXPositionAttribute as String)
        }
        try set(positionValue, attribute: kAXPositionAttribute, on: element, operation: "Set window position")
    }

    static func setMinimized(_ minimized: Bool, for element: AXUIElement) throws {
        let value: CFBoolean = minimized ? kCFBooleanTrue : kCFBooleanFalse
        try set(value, attribute: kAXMinimizedAttribute as String,
                on: element, operation: minimized ? "Minimize window" : "Restore window")
    }

    static func raise(_ element: AXUIElement) {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    static func flipPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// The window under a point (Accessibility hit test), in AX coordinates.
    static func window(at point: CGPoint) -> WindowInfo? {
        let system = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success,
              let element else { return nil }
        var windowRaw: CFTypeRef?
        var windowElement = element
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowRaw) == .success,
           let windowRaw, CFGetTypeID(windowRaw) == AXUIElementGetTypeID() {
            windowElement = windowRaw as! AXUIElement
        }
        guard let frame = frame(of: windowElement) else { return nil }
        var titleRaw: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &titleRaw)
        var pid: pid_t = 0
        AXUIElementGetPid(windowElement, &pid)
        return WindowInfo(id: "\(pid)-hit", title: titleRaw as? String ?? "Window",
                          appName: "", element: windowElement, frame: frame, pid: pid)
    }

    static func focus(_ element: AXUIElement) {
        _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    static func isFullScreen(_ element: AXUIElement) -> Bool {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &raw) == .success else { return false }
        return (raw as? Bool) ?? false
    }

    static func setFullScreen(_ value: Bool, for element: AXUIElement) {
        _ = AXUIElementSetAttributeValue(element, "AXFullScreen" as CFString,
                                         value ? kCFBooleanTrue : kCFBooleanFalse)
    }

    private static func point(attribute: String, of element: AXUIElement) -> CGPoint? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let value = raw,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var result = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &result) else {
            return nil
        }
        return result
    }

    private static func size(attribute: String, of element: AXUIElement) -> CGSize? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let value = raw,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var result = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &result) else {
            return nil
        }
        return result
    }

    private static func attributeString(_ attribute: String, of element: AXUIElement) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw as? String
    }

    static func isMinimized(_ element: AXUIElement) -> Bool {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXMinimizedAttribute as CFString, &raw
        ) == .success else {
            return false
        }
        return (raw as? Bool) ?? false
    }

    private static func set(
        _ value: CFTypeRef,
        attribute: String,
        on element: AXUIElement,
        operation: String
    ) throws {
        let result = AXUIElementSetAttributeValue(element, attribute as CFString, value)
        guard result == .success else {
            throw WindowError.accessibility(result, operation)
        }
    }
}
