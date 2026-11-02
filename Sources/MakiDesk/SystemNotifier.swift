import AppKit
import Foundation
import UserNotifications

/// System notifications, opt-in (the HUD is the default channel).
///
/// The HUD is always shown: it needs no permission, follows the app theme and
/// is excluded from screenshots. A user who wants the alert in Notification
/// Center — where macOS also applies Focus and Do Not Disturb — can ask for a
/// second copy here. Permission is requested only when that option is switched
/// on, never at launch.
@MainActor
final class SystemNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = SystemNotifier()

    /// `UNUserNotificationCenter.current()` asserts when the process is not a
    /// bundled app, which is the case for `swift run` and the test runner.
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    private var center: UNUserNotificationCenter?

    private override init() {
        super.init()
        guard Self.isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        self.center = center
    }

    /// Asks once. Returns whether the app may post notifications now.
    func requestAuthorization() async -> Bool {
        guard let center else { return false }
        do {
            return try await center.requestAuthorization(options: [.alert])
        } catch {
            return false
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        guard let center else { return .denied }
        return await center.notificationSettings().authorizationStatus
    }

    /// Best effort: a denied permission silences this copy, never the HUD.
    func post(title: String, body: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        center.add(request)
    }

    /// A menu-bar app is often "active" while the user is elsewhere; without
    /// this the banner would be suppressed exactly when it is needed.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}
