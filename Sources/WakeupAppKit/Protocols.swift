public enum HelperClientError: Error, Equatable {
    /// The helper ran the request and reported a failure.
    case helper(String)
    /// The helper could not be reached, or the connection broke mid-request.
    case connection(String)
    /// The app has no Team ID signature, so it cannot verify the helper.
    case unsigned
}

/// The app's view of the root helper.
public protocol HelperControlling: Sendable {
    func enable(lowPowerOnBattery: Bool) async throws
    func disable() async throws
    func setLowPowerOnBattery(_ on: Bool) async throws
    /// True while the helper still considers the mode on.
    func heartbeat() async throws -> Bool
    func isEnabled() async throws -> Bool
}

/// Registration of the helper daemon with the system.
public protocol HelperRegistering: Sendable {
    func availability() -> HelperAvailability
    func register() throws
    func openApprovalSettings()
}
