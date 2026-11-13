import Foundation
import UserNotifications

/// Posts banner notifications. Only works inside an app bundle (`UNUserNotificationCenter` needs one).
public final class UserNotificationNotifier: Notifying, NotificationAuthorizing, Sendable {
    public init() {}

    public func permission() async -> NotificationPermission {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: NotificationPermission(settings.authorizationStatus))
            }
        }
    }

    public func requestPermission() async -> NotificationPermission {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        return await permission()
    }

    /// Never asks for permission by itself: without it macOS drops the notification, and the menu still shows the reason.
    public func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
