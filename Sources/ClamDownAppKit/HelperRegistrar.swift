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

    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }

    /// macOS reports notFound, not notRegistered, for a helper that was never registered,
    /// so both states get a registration attempt. A registered helper is never registered again.
    var canAttemptRegistration: Bool {
        self == .notRegistered || isUnavailable
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

    /// Uses the completion-handler variant: the plain `unregister()` returns while the helper is still being removed.
    /// Even so, macOS refuses a registration for a moment afterwards, so the caller waits before it registers.
    public func unregister() async throws {
        try await SMAppService.daemon(plistName: plistName).unregister()
    }

    public func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
