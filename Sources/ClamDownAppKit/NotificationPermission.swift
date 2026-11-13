import UserNotifications

/// What macOS lets ClamDown do with notifications.
public enum NotificationPermission: Equatable, Sendable {
    /// The user has never been asked.
    case notAsked
    case allowed
    case denied

    public init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notAsked
        case .denied: self = .denied
        default: self = .allowed
        }
    }

    /// What Settings offers next to "Notify When Switched Off": nothing while the setting is off or macOS agrees.
    public func hint(settingOn: Bool) -> NotificationHint {
        guard settingOn else { return .nothing }
        switch self {
        case .notAsked: return .allow
        case .denied: return .openSettings
        case .allowed: return .nothing
        }
    }
}

public enum NotificationHint: Equatable, Sendable {
    case nothing
    /// Offer the system prompt.
    case allow
    /// The user said no before; only System Settings can change that.
    case openSettings
}

/// Reads and requests the notification permission. Requesting shows a system prompt, so only a button may call it.
public protocol NotificationAuthorizing: Sendable {
    func permission() async -> NotificationPermission
    /// Shows the system prompt when the user was never asked. Returns the permission afterwards.
    func requestPermission() async -> NotificationPermission
}
