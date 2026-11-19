import ApplicationServices
import CoreGraphics
import Foundation

enum WindowDragTapMessage: @unchecked Sendable {
    case began(WindowController.WindowInfo, CGPoint)
    case pointerMoved(CGPoint)
    case modifierChanged(Bool)
    case ended(CGPoint, shouldSnap: Bool, didMove: Bool)
    case availability(Bool)
}

/// Active input tap for the opt-in Option-drag-from-anywhere gesture.
/// All gesture state is owned by the tap's run-loop thread; AX messaging is
/// object-local and bounded before the callback touches a target window.
final class WindowDragInputTap: @unchecked Sendable {
    private static let eventMarker: Int64 = 0x4D616B6944726167
    private static let threshold: CGFloat = 4
    private static let axTimeout: Float = 0.08

    private let lock = NSLock()
    private let onMessage: @Sendable (WindowDragTapMessage) -> Void
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var isRunning = false

    // These fields are read and written only by the event-tap callback thread.
    private var originalDown: CGEvent?
    private var target: WindowController.WindowInfo?
    private var downPoint = CGPoint.zero
    private var titleBarPoint = CGPoint.zero
    private var lastNativePoint = CGPoint.zero
    private var translation = CGPoint.zero
    private var moved = false
    private var nativeDragStarted = false
    private var optionHeld = false

    init(onMessage: @escaping @Sendable (WindowDragTapMessage) -> Void) {
        self.onMessage = onMessage
    }

    static func isSynthesizedMouseEvent(_ event: CGEvent?) -> Bool {
        event?.getIntegerValueField(.eventSourceUserData) == eventMarker
    }

    func start() {
        lock.lock()
        guard !isRunning else { lock.unlock(); return }
        isRunning = true
        lock.unlock()

        let thread = Thread { [weak self] in self?.run() }
        thread.name = "com.makidesk.window-drag-events"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        lock.lock()
        let tap = self.tap
        let runLoop = self.runLoop
        isRunning = false
        lock.unlock()

        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
            self.cancelGesture()
            if let tap { CFMachPortInvalidate(tap) }
            CFRunLoopStop(runLoop)
        }
        CFRunLoopWakeUp(runLoop)
    }

    private func run() {
        let mask = [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged]
            .reduce(into: CGEventMask(0)) { $0 |= CGEventMask(1) << $1.rawValue }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            lock.lock()
            isRunning = false
            lock.unlock()
            onMessage(.availability(false))
            return
        }

        let runLoop = CFRunLoopGetCurrent()
        lock.lock()
        guard isRunning else {
            lock.unlock()
            CFMachPortInvalidate(tap)
            return
        }
        self.tap = tap
        self.runLoop = runLoop
        lock.unlock()

        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        onMessage(.availability(true))
        CFRunLoopRun()
        CFRunLoopRemoveSource(runLoop, source, .commonModes)

        lock.lock()
        self.tap = nil
        self.runLoop = nil
        isRunning = false
        lock.unlock()
    }

    private func handle(_ type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock()
            let tap = self.tap
            lock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            cancelGesture()
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.eventSourceUserData) != Self.eventMarker else {
            return Unmanaged.passUnretained(event)
        }

        if type == .flagsChanged {
            let held = event.flags.contains(.maskAlternate)
            if held != optionHeld {
                optionHeld = held
                if target != nil { onMessage(.modifierChanged(held)) }
            }
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .leftMouseDown:
            guard target == nil,
                  event.flags.contains(.maskAlternate),
                  let hit = Self.window(at: event.location),
                  hit.pid != ProcessInfo.processInfo.processIdentifier else {
                return Unmanaged.passUnretained(event)
            }
            AXUIElementSetMessagingTimeout(hit.element, Self.axTimeout)
            _ = AXUIElementPerformAction(hit.element, kAXRaiseAction as CFString)
            _ = AXUIElementSetAttributeValue(hit.element, kAXMainAttribute as CFString,
                                             kCFBooleanTrue)
            target = hit
            originalDown = event.copy()
            downPoint = event.location
            lastNativePoint = event.location
            optionHeld = true
            moved = false
            nativeDragStarted = false
            onMessage(.began(hit, event.location))
            return nil

        case .leftMouseDragged:
            guard let target else { return Unmanaged.passUnretained(event) }
            let pointerPoint = event.location
            onMessage(.pointerMoved(pointerPoint))
            if !moved {
                let dx = pointerPoint.x - downPoint.x
                let dy = pointerPoint.y - downPoint.y
                guard hypot(dx, dy) >= Self.threshold else { return nil }
                moved = true
                let frame = target.frame
                let titleBarOffset: CGFloat =
                    ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? 4 : 3
                titleBarPoint = CGPoint(x: frame.midX.rounded(),
                                        y: frame.minY + titleBarOffset)
                translation = CGPoint(x: titleBarPoint.x - downPoint.x,
                                      y: titleBarPoint.y - downPoint.y)
                event.type = .leftMouseDown
                event.location = titleBarPoint
                event.flags = event.flags.subtracting(.maskAlternate)
                event.setIntegerValueField(.mouseEventClickState, value: 1)
                event.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
                nativeDragStarted = true
                lastNativePoint = event.location
                return Unmanaged.passUnretained(event)
            }
            event.location = CGPoint(x: event.location.x + translation.x,
                                     y: event.location.y + translation.y)
            lastNativePoint = event.location
            event.flags = event.flags.subtracting(.maskAlternate)
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
            return Unmanaged.passUnretained(event)

        case .leftMouseUp:
            guard target != nil else { return Unmanaged.passUnretained(event) }
            let point = event.location
            let shouldSnap = optionHeld
            let didMove = moved
            if nativeDragStarted {
                event.location = CGPoint(x: point.x + translation.x,
                                         y: point.y + translation.y)
                lastNativePoint = event.location
                event.flags = event.flags.subtracting(.maskAlternate)
                event.setIntegerValueField(.mouseEventClickState, value: 1)
                event.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
            } else {
                replayOriginalDown()
            }
            clearGesture()
            onMessage(.ended(point, shouldSnap: shouldSnap, didMove: didMove))
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func replayOriginalDown() {
        guard let down = originalDown?.copy() else { return }
        down.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
        down.post(tap: .cghidEventTap)
    }

    private func cancelGesture() {
        if nativeDragStarted {
            let release = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                  mouseCursorPosition: lastNativePoint, mouseButton: .left)
            release?.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
            release?.post(tap: .cghidEventTap)
        } else if target != nil {
            replayOriginalDown()
            let release = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                  mouseCursorPosition: downPoint, mouseButton: .left)
            release?.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
            release?.post(tap: .cghidEventTap)
        }
        if target != nil {
            onMessage(.ended(downPoint, shouldSnap: false, didMove: moved))
        }
        clearGesture()
    }

    private func clearGesture() {
        target = nil
        originalDown = nil
        moved = false
        nativeDragStarted = false
        optionHeld = false
        translation = .zero
    }

    private static func window(at point: CGPoint) -> WindowController.WindowInfo? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, axTimeout)
        var hitElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y),
                                               &hitElement) == .success,
              let hitElement else { return nil }
        AXUIElementSetMessagingTimeout(hitElement, axTimeout)
        if shouldPassThroughDragTarget(hitElement) { return nil }

        var rawWindow: CFTypeRef?
        let element: AXUIElement
        if AXUIElementCopyAttributeValue(hitElement, kAXWindowAttribute as CFString,
                                         &rawWindow) == .success,
           let rawWindow, CFGetTypeID(rawWindow) == AXUIElementGetTypeID() {
            element = rawWindow as! AXUIElement
        } else {
            element = hitElement
        }
        AXUIElementSetMessagingTimeout(element, axTimeout)

        var positionRaw: CFTypeRef?
        var sizeRaw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString,
                                            &positionRaw) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString,
                                            &sizeRaw) == .success,
              let positionRaw, let sizeRaw,
              CFGetTypeID(positionRaw) == AXValueGetTypeID(),
              CFGetTypeID(sizeRaw) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRaw as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRaw as! AXValue, .cgSize, &size),
              size.width > 36, size.height > 10 else { return nil }
        // Preserve title-bar controls and Finder's draggable proxy icon. They
        // occupy this small leading corner and have their own native actions.
        if point.x <= origin.x + 54, point.y >= origin.y, point.y <= origin.y + 32 {
            return nil
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        let frame = CGRect(origin: origin, size: size)
        return WindowController.WindowInfo(
            id: "\(pid)-drag-hit", title: "Window", appName: "Application",
            element: element, frame: frame, pid: pid)
    }

    private static func shouldPassThroughDragTarget(_ element: AXUIElement) -> Bool {
        var roleRaw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString,
                                            &roleRaw) == .success,
              let role = roleRaw as? String else { return false }
        // Keep native drags for Finder items and other clearly draggable
        // content. The window drag is intended for the surrounding surface.
        return ["AXIcon", "AXImage", "AXCell", "AXRow", "AXOutlineRow",
                "AXCollectionItem", "AXLink"].contains(role)
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        return Unmanaged<WindowDragInputTap>.fromOpaque(userInfo)
            .takeUnretainedValue().handle(type, event: event)
    }
}
