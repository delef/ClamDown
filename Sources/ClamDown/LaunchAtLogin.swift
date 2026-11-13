import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func apply(_ on: Bool) throws {
        let service = SMAppService.mainApp
        if on {
            if service.status != .enabled { try service.register() }
        } else if service.status == .enabled {
            try service.unregister()
        }
    }
}

/// What the Launch at Login switch reads and changes. The app uses the system's login item;
/// debug previews use one that lives in memory, so looking at a screen cannot change the real setting.
@MainActor
struct LoginItem {
    var isEnabled: () -> Bool
    var apply: (Bool) throws -> Void

    static let system = LoginItem(isEnabled: { LaunchAtLogin.isEnabled }, apply: { try LaunchAtLogin.apply($0) })
}
