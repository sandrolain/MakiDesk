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
            let restore = builtInAssistiveTechnologyEnabled
                || !isChromiumBundle(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)

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
