import AppKit

/// Links into System Settings.
enum SystemSettings {
    /// Opens Notifications, on ClamDown's own page where macOS supports the app identifier in the link.
    static func openNotifications() {
        let identifier = Bundle.main.bundleIdentifier ?? ""
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(identifier)") else { return }
        NSWorkspace.shared.open(url)
    }
}
