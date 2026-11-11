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
