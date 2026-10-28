import AppKit
import ApplicationServices
@preconcurrency import CoreFoundation

/// Coordinates AXEnhancedUserInterface around external window geometry writes.
/// Rectangle leaves it disabled for Chromium browsers because restoring it can
/// trigger expensive web accessibility work.
enum AXEnhancedUIController {
    private static let chromiumBundleFamilies = [
        "com.google.Chrome",
        "org.chromium.Chromium",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "company.thebrowser.Browser",
        "company.thebrowser.dia"
    ]

    private static let processLocks = ProcessLockRegistry()
    private static var enhancedUIAttribute: CFString { "AXEnhancedUserInterface" as CFString }

    static func isChromiumBundle(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return chromiumBundleFamilies.contains {
            bundleIdentifier == $0 || bundleIdentifier.hasPrefix("\($0).")
        }
    }

    /// Whether the attribute this call disabled must be put back afterwards.
    /// Chromium keeps it off (restoring it triggers expensive web accessibility
    /// work); assistive technology always wins, so anything we disabled is
    /// restored.
    static func shouldRestoreEnhancedUI(wasEnabled: Bool, isChromium: Bool,
                                        assistiveTechnology: Bool) -> Bool {
        guard wasEnabled else { return false }
        return assistiveTechnology || !isChromium
    }

    static func applicationDidTerminate(pid: pid_t) {
        processLocks.remove(pid: pid)
    }

    static func disableForChromiumApplication(pid: pid_t) {
        guard !builtInAssistiveTechnologyEnabled,
              let bundleIdentifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
              isChromiumBundle(bundleIdentifier) else { return }

        processLocks.withLock(for: pid) {
            let application = applicationElement(pid: pid)
            guard readEnhancedUI(application),
                  AXUIElementSetAttributeValue(application, enhancedUIAttribute, kCFBooleanFalse) == .success else {
                return
            }
            makiLog.notice("Disabled AXEnhancedUserInterface for Chromium app pid=\(pid, privacy: .public)")
        }
    }

    /// Runs one geometry write with the attribute temporarily off.
    ///
    /// The attribute is read again for every write, on purpose (T51). It can
    /// change while the app is open (an assistive tool turning Live Text on, the
    /// app being restarted), and a cached answer could either skip a restore or
    /// restore something this code never disabled. Sampling once per session was
    /// considered and rejected; the read is bounded by the 0.1 s messaging
    /// timeout and runs on the frame-write worker, never on the main thread.
    static func performFrameAdjustment(
        for window: AXUIElement,
        operation: () throws -> Void
    ) rethrows {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success, pid > 0 else {
            try operation()
            return
        }

        try processLocks.withLock(for: pid) {
            let application = applicationElement(pid: pid)
            let wasEnabled = readEnhancedUI(application)
            let disabled = wasEnabled && AXUIElementSetAttributeValue(
                application, enhancedUIAttribute, kCFBooleanFalse
            ) == .success
            let restore = Self.shouldRestoreEnhancedUI(
                wasEnabled: wasEnabled,
                isChromium: isChromiumBundle(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier),
                assistiveTechnology: builtInAssistiveTechnologyEnabled
            )

            defer {
                if disabled && restore {
                    _ = AXUIElementSetAttributeValue(application, enhancedUIAttribute, kCFBooleanTrue)
                }
            }
            try operation()
        }
    }

    private static var builtInAssistiveTechnologyEnabled: Bool {
        NSWorkspace.shared.isVoiceOverEnabled || NSWorkspace.shared.isSwitchControlEnabled
    }

    private static func applicationElement(pid: pid_t) -> AXUIElement {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.1)
        return application
    }

    private static func readEnhancedUI(_ application: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, enhancedUIAttribute, &value) == .success else {
            return false
        }
        return value as? Bool ?? false
    }

    private final class ProcessLockRegistry: @unchecked Sendable {
        private let registryLock = NSLock()
        private var locks: [pid_t: NSLock] = [:]

        func withLock<T>(for pid: pid_t, operation: () throws -> T) rethrows -> T {
            registryLock.lock()
            let processLock = locks[pid] ?? NSLock()
            locks[pid] = processLock
            registryLock.unlock()

            processLock.lock()
            defer { processLock.unlock() }
            return try operation()
        }

        func remove(pid: pid_t) {
            registryLock.lock()
            locks[pid] = nil
            registryLock.unlock()
        }
    }
}
