import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum WindowController {
    enum FrameWriteOrder: Equatable, Sendable {
        case positionThenSize
        case sizeThenPosition
    }
    enum ShortcutAction: Equatable {
        case leftHalf, rightHalf, topHalf, bottomHalf
        case topLeft, topRight, bottomLeft, bottomRight
        case centerCycle, center, phi, toggleFullScreen, minimize
        case switchWindows, switchWindowsBack, searchWindows
        /// Add/remove the frontmost window to group `slot` (1…9).
        case assignToGroup(Int)
        /// Bring group `slot` on screen and lay it out.
        case recallGroup(Int)
        /// Designate the frontmost window for the peek, or take the designation
        /// away when it already is that window (T16).
        case peekDesignate
        /// Send the frontmost window away while the rest stay in use (T17).
        case putAwayFront
        /// Everything the scene put away comes back, leaving no scene.
        case showEverything
        /// One step back: the previous scene, and where its windows were.
        case undoStep
        /// Lay every window **in view** out in a grid, or a golden spiral (T18).
        case gridLayout
        case spiralLayout
        /// Let the advisor choose between the two for what is in view, and offer
        /// it or apply it (T18).
        case suggestLayout
        /// Areas proportional to the content seen in each window (T30).
        case contentLayout
        /// Show or hide the notes panel (T20).
        case toggleNotes
        /// Show or hide the clipboard history (T21).
        case clipboardHistory
        /// Show or hide the shelf (T31).
        case toggleShelf
        /// Select an area of the screen and copy the text it contains (T41).
        case recognizeText
        /// Pick the colour under one point of the screen (T36).
        case sampleColor
        /// Measure an area of the screen (T39).
        case measureArea
        /// Open a utility window without touching other apps (T53).
        case openSettings
        case openKeyboardShortcuts
        case openScreenshots
        /// Toggle presentation the user configured in Settings.
        case toggleFocusBorder
        case toggleMiniMap
        /// Dim everything outside the focused window (T62).
        case toggleFocusDim
        /// Act on the current selection, group or pending advice.
        case focusSelection
        case leaveGroup
        case clearPeek
        case applySuggestedLayout
    }

    /// A value snapshot of one window.
    ///
    /// Discovery builds these on a worker and publishes them to the main actor.
    /// `AXUIElement` is an immutable Core Foundation handle whose API is safe to
    /// call from any thread, and the snapshot is copied rather than mutated in
    /// place once handed off, so transferring it between threads is sound.
    struct WindowInfo: Identifiable, @unchecked Sendable {
        var id: String
        let title: String
        let appName: String
        let element: AXUIElement
        var frame: CGRect
        let pid: pid_t
        /// On-screen window number (`kCGWindowNumber`), when it could be matched.
        /// Used as the handle for ScreenCaptureKit and as a stable identity
        /// fallback.
        var windowID: CGWindowID?
        var minimized: Bool = false
        /// In macOS full screen, read with the rest of the window on the worker so
        /// layout commands need no per-window Accessibility read on the main thread.
        var fullScreen = false
        /// Front-to-back stacking order (0 = frontmost). `Int.max` when unknown.
        var zIndex: Int = Int.max
        var temporarilyUnavailable = false
    }

    /// One discovery result: windows plus the applications that timed out and
    /// the stacking order. Same transfer invariant as `WindowInfo`.
    struct WindowInventoryRead: @unchecked Sendable {
        var windows: [WindowInfo]
        var unavailablePIDs: Set<pid_t> = []
        var stackingOrder: [CGWindowID: Int] = [:]
    }

    /// Which manipulation operations a window actually supports. Electron apps
    /// and panels often refuse some of them; commands must report that instead
    /// of failing silently.
    struct Capabilities {
        var standard = true
        var movable = true
        var resizable = true

        var manageable: Bool { standard && movable && resizable }
    }

    enum WindowError: LocalizedError {
        case invalidFrame(String)
        case accessibility(AXError, String)
        /// The app refused the requested geometry (min/max size constraints).
        case sizeRefused(String)

        var errorDescription: String? {
            switch self {
            case let .invalidFrame(attribute):
                return "Unable to read window \(attribute)"
            case let .accessibility(code, operation):
                return "\(operation) failed (\(code.rawValue))"
            case let .sizeRefused(operation):
                return "\(operation) limited by the app"
            }
        }
    }

    static func requestAccessibilityPermission() -> Bool {
        guard !AXIsProcessTrusted() else { return true }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    static func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Capabilities

    static func capabilities(of element: AXUIElement) -> Capabilities {
        var capabilities = Capabilities()
        if let subrole = attributeString(kAXSubroleAttribute, of: element) {
            capabilities.standard = subrole == kAXStandardWindowSubrole as String
        }
        capabilities.movable = bool(attribute: "AXMovable", of: element) ?? true
        capabilities.resizable = bool(attribute: "AXResizable", of: element) ?? true
        return capabilities
    }

    // MARK: - Discovery

    /// Every window the user can act on, front-to-back.
    ///
    /// What is deliberately left out, and why (T25):
    /// - the **desktop** and other full-screen backgrounds, which are not windows
    ///   at all (see `isDesktopWindow`);
    /// - a window with no frame that is not minimised: accessibility cannot say
    ///   where it is, so it can neither be listed nor arranged;
    /// - windows of apps that are **not `.regular`** — menu-bar agents, panel
    ///   apps — unless they are real user windows with a title and a frame (see
    ///   `isAgentWindow`): an agent's settings window is listed, its widget is not.
    static func discoverWindows(includeMinimized: Bool = false) -> [WindowInfo] {
        discoverInventory(includeMinimized: includeMinimized).windows
    }

    static func discoverInventory(includeMinimized: Bool = false, onlyPIDs: Set<pid_t>? = nil) -> WindowInventoryRead {
        var unavailable = Set<pid_t>()
        let order = cgWindowOrder()
        // The all-windows list names a window Core Graphics knows even when it is
        // in the Dock, which is what keeps a minimised window's identity stable
        // across its siblings being reordered (T25).
        let numbers = cgWindowNumbers()
        let orderByPID = Dictionary(grouping: order, by: \.pid)
        let numbersByPID = Dictionary(grouping: numbers, by: \.pid)
        let stackRanks = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element.number, $0.offset) })
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let discovered: [WindowInfo] = NSWorkspace.shared.runningApplications
            .filter {
                !$0.isTerminated &&
                (onlyPIDs?.contains($0.processIdentifier) ?? true) &&
                $0.activationPolicy != .prohibited &&
                $0.processIdentifier != ownPID
            }

            .flatMap { app -> [WindowInfo] in
                let pid = app.processIdentifier
                let appOrder = orderByPID[pid] ?? []
                let appNumbers = numbersByPID[pid] ?? []
                let agent = app.activationPolicy != .regular
                let appElement = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(appElement, 0.1)
                let deadline = Date().addingTimeInterval(0.5)
                var encounteredTimeout = false
                var value: CFTypeRef?
                let read = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
                guard read == .success, let windows = value as? [AXUIElement] else {
                    if read == .cannotComplete || read == .failure || read == .apiDisabled { unavailable.insert(pid) }
                    return []
                }

                var usedIDs = Set<String>()
                // A window number is claimed once per read: windows that share a
                // frame keep distinct identities (T25).
                var claimedScreenNumbers = Set<CGWindowID>()
                var claimedNumbers = Set<CGWindowID>()
                return windows.enumerated().compactMap { (index, element) -> WindowInfo? in
                    // Healthy apps with many windows must not be truncated.
                    // Stop a slow pass only after communication has failed.
                    guard !encounteredTimeout || Date() < deadline else { unavailable.insert(pid); return nil }
                    AXUIElementSetMessagingTimeout(element, 0.05)
                    var titleValue: CFTypeRef?
                    let result = AXUIElementCopyAttributeValue(
                        element, kAXTitleAttribute as CFString, &titleValue
                    )
                    if result == .cannotComplete || result == .failure {
                        encounteredTimeout = true
                        unavailable.insert(pid)
                    }
                    let rawTitle = result == .success ? titleValue as? String : nil
                    let minimized = isMinimized(element)
                    if !includeMinimized, minimized { return nil }
                    guard let frame = frame(of: element) ?? (minimized ? .zero : nil) else {
                        encounteredTimeout = true
                        unavailable.insert(pid)
                        return nil
                    }
                    if isDesktopWindow(element, frame: frame) { return nil }
                    // A window of an app that is not `.regular` counts only when
                    // the window server shows it where windows live: Notification
                    // Center's panel floats at level 21 and its desktop widgets at
                    // level −2147483601, above every app — no window the user can
                    // switch to or arrange (T25).
                    if agent, !isAgentWindow(subrole: attributeString(kAXSubroleAttribute, of: element),
                                             title: rawTitle, frame: frame,
                                             layer: cgLayer(for: frame, pid: pid, in: appNumbers)) {
                        return nil
                    }
                    let cgID = windowNumber(for: frame, pid: pid, title: rawTitle, in: appOrder,
                                            used: &claimedScreenNumbers)
                    var identifier = stableID(pid: pid,
                                              identifier: attributeString(kAXIdentifierAttribute, of: element),
                                              windowNumber: windowNumber(for: frame, pid: pid, title: rawTitle,
                                                                         in: appNumbers, used: &claimedNumbers),
                                              index: index)
                    if usedIDs.contains(identifier) {
                        identifier += "-\(index)"
                    }
                    usedIDs.insert(identifier)
                    return WindowInfo(
                        id: identifier,
                        title: rawTitle ?? "Untitled window",
                        appName: app.localizedName ?? "Application",
                        element: element,
                        frame: frame,
                        pid: pid,
                        windowID: cgID,
                        minimized: minimized,
                        fullScreen: !minimized && isFullScreen(element),
                        zIndex: cgID.flatMap { stackRanks[$0] } ?? Int.max,
                        temporarilyUnavailable: result == .cannotComplete || result == .failure
                    )
                }
            }
        // Front-to-back so array order reflects the real window stack.
        let sorted = discovered.sorted {
            $0.zIndex == $1.zIndex ? $0.id < $1.id : $0.zIndex < $1.zIndex
        }
        return WindowInventoryRead(windows: sorted, unavailablePIDs: unavailable, stackingOrder: stackRanks)
    }

    /// Whether an element is the **desktop** — or another full-screen background —
    /// rather than a window the user can use (T26).
    ///
    /// The desktop is not a window: the Finder reports it as a full-screen
    /// `AXScrollArea` with no subrole, and where a system reports it as a window
    /// it carries no window subrole either. Testing the *role and subrole*
    /// instead of the title is what stops a real window that simply has no title
    /// from being dropped along with it.
    static func isDesktopWindow(_ element: AXUIElement, frame: CGRect?) -> Bool {
        if let role = attributeString(kAXRoleAttribute, of: element),
           role != kAXWindowRole as String {
            return true
        }
        guard let frame, coversScreen(frame) else { return false }
        return !isWindowSubrole(attributeString(kAXSubroleAttribute, of: element) ?? "")
    }

    /// Whether a window of an app that is not `.regular` is one the user can use
    /// (T25): a real window subrole, a title, a frame **and** the normal window
    /// level. A menu-bar agent's settings or document window counts; its widget,
    /// menu-bar strip, overlay or panel does not — Notification Center's panel
    /// runs above every app (level 21) and so do its desktop widgets
    /// (level −2147483601), and neither is a window you can switch to.
    static func isAgentWindow(subrole: String?, title: String?, frame: CGRect?, layer: Int?) -> Bool {
        guard let title, !title.trimmingCharacters(in: .whitespaces).isEmpty, frame != nil else { return false }
        // Unknown level: the window server does not see it as a window, so it is
        // not one to list.
        guard layer == 0 else { return false }
        return isWindowSubrole(subrole ?? "")
    }

    /// The subroles carried by a window the user can act on. Anything else —
    /// widgets, strips, overlays — is a helper element, not a window (T25).
    private static func isWindowSubrole(_ subrole: String) -> Bool {
        [kAXStandardWindowSubrole, kAXDialogSubrole, kAXSystemDialogSubrole,
         kAXFloatingWindowSubrole, kAXSystemFloatingWindowSubrole]
            .contains { $0 as String == subrole }
    }

    /// A stable identity independent of the (constantly changing) window title:
    /// the Core Graphics window number first — it is unique per window and
    /// survives the window being raised, moved, minimised, or its siblings being
    /// reordered — then the app-provided `AXIdentifier`, then the enumeration
    /// index, which is a last resort: it changes as soon as a sibling opens or
    /// closes, so it must not be the identity of a window Core Graphics knows.
    static func stableID(pid: pid_t, identifier: String?, windowNumber: CGWindowID?, index: Int) -> String {
        if let windowNumber {
            return "\(pid)-cg\(windowNumber)"
        }
        if let identifier, !identifier.isEmpty {
            return "\(pid)-\(identifier)"
        }
        return "\(pid)-idx\(index)"
    }

    /// On-screen windows in front-to-back order, matched to Accessibility windows
    /// by owning process and frame so the mini-map can respect the real stack.
    private static func cgWindowOrder() -> [CGWindowEntry] {
        cgWindowList([.optionOnScreenOnly, .excludeDesktopElements])
    }

    /// Every window Core Graphics knows, minimised ones included: the source of
    /// a window's stable identity. The on-screen list alone cannot name a window
    /// that is in the Dock (T25).
    private static func cgWindowNumbers() -> [CGWindowEntry] {
        cgWindowList([.optionAll])
    }

    /// One window Core Graphics knows about.
    struct CGWindowEntry {
        let pid: pid_t
        let frame: CGRect
        let number: CGWindowID
        /// The window's own title, when Screen Recording lets Core Graphics
        /// report it. Used only to tell apart windows of one app that share a
        /// frame (T25).
        let name: String?
        /// The window level: 0 is where application windows live, anything else
        /// floats above them (panels, widgets, menu-bar strips).
        let layer: Int
        /// The window's alpha; 0 marks a window the app keeps but does not
        /// show, which must not be used as a focus anchor (T62).
        let alpha: CGFloat
    }

    /// The on-screen windows in front-to-back order, for overlays that place
    /// themselves in the stack instead of by geometry (T62).
    static func onScreenStack() -> [CGWindowEntry] {
        cgWindowOrder()
    }

    private static func cgWindowList(_ options: CGWindowListOption) -> [CGWindowEntry] {
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { entry in
            guard let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else {
                return nil
            }
            let number = CGWindowID((entry[kCGWindowNumber as String] as? NSNumber)?.intValue ?? 0)
            let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            return CGWindowEntry(pid: pid, frame: frame, number: number,
                                 name: entry[kCGWindowName as String] as? String,
                                 layer: layer, alpha: CGFloat(alpha))
        }
    }

    /// The window level of the window server's window closest to `frame` for
    /// `pid`, or `nil` when the window server does not know one. Only used to
    /// tell a real window of a helper app from a panel or widget, so it takes
    /// the closest match rather than claiming a number (T25).
    private static func cgLayer(for frame: CGRect, pid: pid_t, in list: [CGWindowEntry]) -> Int? {
        var best: (score: CGFloat, layer: Int)?
        for item in list where item.pid == pid {
            let score = frameScore(item.frame, frame)
            guard score <= 40 else { continue }
            if best == nil || score < best!.score { best = (score, item.layer) }
        }
        return best?.layer
    }

    /// How far two frames are apart, over all four edges.
    private static func frameScore(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }

    private static func stackingIndex(for pid: pid_t, frame: CGRect, in order: [CGWindowEntry]) -> Int {
        var bestIndex = Int.max
        var bestScore = CGFloat.greatestFiniteMagnitude
        for (index, item) in order.enumerated() where item.pid == pid {
            let score = frameScore(item.frame, frame)
            if score < bestScore {
                bestScore = score
                bestIndex = index
            }
        }
        // Require a reasonably close match; otherwise treat as unknown.
        return bestScore <= 40 ? bestIndex : Int.max
    }

    /// The Core Graphics window number behind an Accessibility window: the
    /// closest frame wins and the title breaks a tie, because several windows of
    /// one app routinely share a frame (macOS *zoom* puts them all at the same
    /// size) and only the title tells them apart. A number is claimed at most
    /// once per read — `used` — so two windows never end up with **one**
    /// identity, which would give them one id and one preview (T25).
    private static func windowNumber(for frame: CGRect, pid: pid_t, title: String?,
                                     in list: [CGWindowEntry],
                                     used: inout Set<CGWindowID>) -> CGWindowID? {
        let wanted = title.flatMap { $0.isEmpty ? nil : $0 }
        var bestNumber: CGWindowID?
        var bestScore = CGFloat.greatestFiniteMagnitude
        var bestNamed = false
        for item in list where item.pid == pid && !used.contains(item.number) {
            let score = frameScore(item.frame, frame)
            guard score <= 40 else { continue }
            let named = wanted != nil && item.name == wanted
            let better = score < bestScore - 1
                || (abs(score - bestScore) <= 1 && named && !bestNamed)
            if better {
                bestScore = score
                bestNamed = named
                bestNumber = item.number
            }
        }
        if let bestNumber { used.insert(bestNumber) }
        return bestNumber
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = point(attribute: kAXPositionAttribute, of: element),
              let size = size(attribute: kAXSizeAttribute, of: element) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    /// What the frontmost application has focused. The desktop is its own case
    /// because it is not a window: clicking it focuses the Finder on the screen
    /// itself, and treating that as a window is what put a box round the whole
    /// screen (T26).
    enum Frontmost {
        case window(WindowInfo)
        case desktop
        case none
    }

    @MainActor
    static func frontmost() -> Frontmost {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return .none
        }
        return readFocusedWindow(pid: app.processIdentifier, appName: app.localizedName,
                                 indexed: WindowIndex.shared.snapshot(includeMinimized: true))
    }

    /// The focused window of `pid`, read through Accessibility. It touches no
    /// main-actor state — the index snapshot comes in as a value — so a worker
    /// can run it and the main thread never waits on the target app.
    nonisolated static func readFocusedWindow(pid: pid_t, appName: String?,
                                              indexed snapshot: [WindowInfo]) -> Frontmost {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.1)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &raw
        ) == .success, let raw,
        CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return .none
        }
        let element = raw as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.1)
        guard let frame = frame(of: element) else { return .none }
        guard !isDesktopWindow(element, frame: frame) else { return .desktop }
        var titleValue: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue)
        // A focused window is on screen by definition, so the all-windows list
        // gives the same number as the on-screen one — and names it even in the
        // moment it is being minimised under a click.
        var claimed = Set<CGWindowID>()
        let indexed = snapshot.first {
            $0.pid == pid && CFEqual($0.element, element)
        }
        let cgID: CGWindowID?
        if let indexed { cgID = indexed.windowID }
        else {
            cgID = windowNumber(for: frame, pid: pid,
                                title: titleValue as? String, in: cgWindowNumbers(), used: &claimed)
        }
        return .window(WindowInfo(
            id: indexed?.id ?? stableID(pid: pid,
                         identifier: attributeString(kAXIdentifierAttribute, of: element),
                         windowNumber: cgID, index: 0),
            title: titleValue as? String ?? "Untitled window",
            appName: appName ?? "Application",
            element: element,
            frame: frame,
            pid: pid,
            windowID: cgID
        ))
    }

    /// The frontmost window, or `nil` when the frontmost app has none — or when
    /// what it has focused is the desktop, which is not a window (T26).
    @MainActor
    static func frontmostWindow() -> WindowInfo? {
        if case let .window(info) = frontmost() { return info }
        return nil
    }

    static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    // Cocoa (bottom-left origin) <-> AX (top-left origin); the flip is its own inverse.
    static func flip(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Live window-server bounds for a window id, in AX (top-left) coordinates.
    /// Unlike an AX read this is cheap and never stalls, so a live drag can be
    /// followed at pointer rate instead of waiting for coalesced AX events.
    static func cgFrame(windowNumber: CGWindowID) -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowNumber) as? [[String: Any]],
              let bounds = info.first?[kCGWindowBounds as String] as? [String: CGFloat],
              let x = bounds["X"], let y = bounds["Y"],
              let width = bounds["Width"], let height = bounds["Height"] else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
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

    /// True when an AX frame lies inside the visible area of some screen.
    static func isOnSomeScreen(_ frame: CGRect) -> Bool {
        NSScreen.screens.contains { screen in
            let visible = axVisibleFrame(for: screen)
            return visible.intersects(frame)
        }
    }

    static func setFrame(_ frame: CGRect, for element: AXUIElement) throws {
        try AXEnhancedUIController.performFrameAdjustment(for: element) {
            try setPosition(frame.origin, for: element)
            try setSize(frame.size, for: element)
        }
    }

    /// Whether an Accessibility element belongs to this process. Moving or
    /// resizing one of our own windows means AppKit runs the write in-process,
    /// and its Accessibility entry point invalidates the text input context on
    /// the calling thread: that must be the main thread.
    static func isOwnProcess(_ element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return false }
        return pid == ProcessInfo.processInfo.processIdentifier
    }

    /// Queues frame writes away from the main actor. Pending intermediate
    /// frames for the same logical window are coalesced, and writes remain
    /// serialized until their position and size updates finish.
    @MainActor
    static func setFrameAsync(_ frame: CGRect, for element: AXUIElement,
                              identity: String, order: FrameWriteOrder = .positionThenSize,
                              completion: (@MainActor () -> Void)? = nil) {
        if isOwnProcess(element) {
            // A worker queue cannot write our own window: AppKit services the
            // write here and the text input manager asserts the main queue.
            do {
                try setFrame(frame, for: element)
            } catch {
                makiLog.error("frame write to our own window failed error=\(error.localizedDescription, privacy: .public)")
            }
            completion?()
            return
        }
        AXFrameWriteCoordinator.shared.enqueue(frame, element: element,
                                               identity: identity, order: order, completion: completion)
    }

    /// Position-only variant for a live drag: the size is left alone, and
    /// repeated points coalesce in the same per-window queue as frame writes.
    @MainActor
    static func setPositionAsync(_ origin: CGPoint, for element: AXUIElement,
                                 identity: String,
                                 completion: (@MainActor () -> Void)? = nil) {
        if isOwnProcess(element) {
            do {
                try setPosition(origin, for: element)
            } catch {
                makiLog.error("position write to our own window failed error=\(error.localizedDescription, privacy: .public)")
            }
            completion?()
            return
        }
        AXFrameWriteCoordinator.shared.enqueuePosition(origin, element: element,
                                                       identity: identity,
                                                       completion: completion)
    }

    /// Sizes a window without touching its position. Kept apart from the move
    /// because some apps accept a size only when it is not written in the same
    /// breath as a position (T27).
    static func setSize(_ size: CGSize, for element: AXUIElement) throws {
        var size = size
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

    /// Presses the window's close button — the same as clicking the red traffic
    /// light — so the app can still show its own "save changes?" prompt.
    @discardableResult
    static func close(_ element: AXUIElement) -> Bool {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXCloseButtonAttribute as CFString, &raw
        ) == .success, let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return false
        }
        return AXUIElementPerformAction(raw as! AXUIElement, kAXPressAction as CFString) == .success
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
        var claimed = Set<CGWindowID>()
        let windowID = windowNumber(for: frame, pid: pid, title: titleRaw as? String,
                                   in: cgWindowOrder(), used: &claimed)
        return WindowInfo(id: "\(pid)-hit", title: titleRaw as? String ?? "Window",
                          appName: "", element: windowElement, frame: frame, pid: pid,
                          windowID: windowID)
    }

    /// Returns true when the focused attribute was actually set.
    @discardableResult
    static func focus(_ element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    static func isFullScreen(_ element: AXUIElement) -> Bool {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &raw) == .success else { return false }
        return (raw as? Bool) ?? false
    }

    /// Returns true when full screen was toggled. Some apps do not expose
    /// `AXFullScreen` at all, in which case the call fails and is reported.
    @discardableResult
    static func setFullScreen(_ value: Bool, for element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(element, "AXFullScreen" as CFString,
                                     value ? kCFBooleanTrue : kCFBooleanFalse) == .success
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

    /// The window's document URL (`AXDocument`), when the app exposes one — the
    /// strongest clue for re-finding the same window after a restart.
    static func document(of element: AXUIElement) -> String? {
        attributeString(kAXDocumentAttribute, of: element)
    }

    private static func bool(attribute: String, of element: AXUIElement) -> Bool? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw as? Bool
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
        switch result {
        case .success:
            return
        case .cannotComplete, .failure:
            // Typical when an app clamps or refuses a window size (min-size /
            // Electron). Reported as a limitation rather than an AX failure.
            throw WindowError.sizeRefused(operation)
        default:
            throw WindowError.accessibility(result, operation)
        }
    }
}
