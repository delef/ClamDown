import Foundation
import UserNotifications

/// Posts banner notifications. Only works inside an app bundle (`UNUserNotificationCenter` needs one).
public final class UserNotificationNotifier: Notifying, @unchecked Sendable {
    private let lock = NSLock()
    private var requestedAuthorization = false

    public init() {}

    /// Asks for permission once. Call at launch so the system prompt shows up early.
    public func requestAuthorization() {
        let shouldRequest = lock.withLock {
            defer { requestedAuthorization = true }
            return !requestedAuthorization
        }
        guard shouldRequest else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    public func post(title: String, body: String) {
        requestAuthorization()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
