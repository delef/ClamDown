import ServiceManagement

public enum HelperAvailability: Equatable, Sendable {
    case ready
    case requiresApproval
    case notRegistered
    case unavailable(String)

    public init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .ready
        case .requiresApproval: self = .requiresApproval
        case .notRegistered: self = .notRegistered
        case .notFound: self = .unavailable("The helper is missing from the app bundle.")
        @unknown default: self = .unavailable("Unknown helper status.")
        }
    }
}

public struct SMAppServiceRegistrar: HelperRegistering {
    private let plistName: String

    /// `plistName` is the daemon plist file name inside `Contents/Library/LaunchDaemons`.
    public init(plistName: String) {
        self.plistName = plistName
    }

    public func availability() -> HelperAvailability {
        HelperAvailability(SMAppService.daemon(plistName: plistName).status)
    }

    public func register() throws {
        try SMAppService.daemon(plistName: plistName).register()
    }

    public func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
