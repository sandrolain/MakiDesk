import AppKit
import ApplicationServices

/// Remembers the keyboard destination before a utility panel takes focus.
/// Each panel owns a session, so nested panels can return to one another.
@MainActor
final class PanelFocusReturn {
    private var restoreAction: (() -> Void)?
    private let captureTarget: () -> (() -> Void)?
    private let applicationIsActive: () -> Bool

    init() {
        captureTarget = { Self.captureCurrentTarget() }
        applicationIsActive = { NSApp.isActive }
    }

    init(captureTarget: @escaping () -> (() -> Void)?,
         applicationIsActive: @escaping () -> Bool) {
        self.captureTarget = captureTarget
        self.applicationIsActive = applicationIsActive
    }

    func capture() {
        restoreAction = captureTarget()
    }

    /// Consume before orderOut: resign-key callbacks can re-enter hide().
    /// A dismissal after the user chose another window must not steal focus.
    func takeRestoreAction(ownsKeyboard: Bool) -> (() -> Void)? {
        let action = restoreAction
        restoreAction = nil
        return ownsKeyboard && applicationIsActive() ? action : nil
    }

    private static func captureCurrentTarget() -> (() -> Void)? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier == ownPID,
           let window = NSApp.keyWindow {
            let responder = window.firstResponder
            return { [weak window, weak responder] in
                guard let window, window.isVisible, !window.isMiniaturized else {
                    if let app = ExternalApplicationFocus.shared.lastApplication, !app.isTerminated {
                        app.activate(options: [])
                    }
                    return
                }
                window.makeKeyAndOrderFront(nil)
                if let responder { window.makeFirstResponder(responder) }
            }
        }

        let app: NSRunningApplication?
        if let frontmost, frontmost.processIdentifier != ownPID {
            app = frontmost
        } else {
            app = ExternalApplicationFocus.shared.lastApplication
        }
        guard let app, !app.isTerminated else { return nil }
        var focusedWindow: AXUIElement?
        if AXIsProcessTrusted() {
            // One focused-window read, with an object-local timeout. Do not
            // discover all windows just to remember a return destination.
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.1)
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString,
                                             &value) == .success,
               let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                let window = value as! AXUIElement
                AXUIElementSetMessagingTimeout(window, 0.1)
                focusedWindow = window
            }
        }
        let target = focusedWindow
        let capturedRevision = ExternalApplicationFocus.shared.activationRevision
        return {
            // A panel may remain visible while the user works in another app
            // and clicks back into it. Return to that more recent destination;
            // an AX window saved on the original opening would now be stale.
            if ExternalApplicationFocus.shared.activationRevision != capturedRevision,
               let latest = ExternalApplicationFocus.shared.lastApplication, !latest.isTerminated {
                latest.activate(options: [])
                return
            }
            guard !app.isTerminated, app.activate(options: []) else { return }
            if let target {
                WindowController.raise(target)
                WindowController.focus(target)
            }
        }
    }
}

/// Menu-bar commands can activate MakiDesk before a panel opens. Keep the
/// external app as a fallback without performing AX reads on activation.
@MainActor
final class ExternalApplicationFocus: NSObject {
    static let shared = ExternalApplicationFocus()
    private(set) var lastApplication: NSRunningApplication?
    private(set) var activationRevision: UInt64 = 0
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        remember(NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(applicationActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    @objc private func applicationActivated(_ notification: Notification) {
        remember(notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
    }

    private func remember(_ app: NSRunningApplication?) {
        guard let app, !app.isTerminated,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        lastApplication = app
        activationRevision &+= 1
    }
}
