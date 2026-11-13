import ClamDownShared

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
    /// Tells the helper how to drive the fans for the rest of this session.
    func setFanPolicy(_ policy: FanPolicy) async throws
    func coolingStatus() async throws -> CoolingStatus
}

/// Reads power, battery and thermal state and reports changes (including wake from sleep).
public protocol SystemMonitoring: AnyObject {
    func snapshot() -> SystemSnapshot
    func start(onChange: @escaping @Sendable () -> Void)
    func stop()
}

/// Shows the user a notification.
public protocol Notifying: Sendable {
    func post(title: String, body: String)
}

/// Keeps the process from being throttled while the mode is on, so timers still fire with the lid closed.
public protocol ProcessActivityHolding: AnyObject {
    func begin()
    func end()
}

/// Registration of the helper daemon with the system.
public protocol HelperRegistering: Sendable {
    func availability() -> HelperAvailability
    func register() throws
    /// Stops the helper and removes its registration. Also needed before registering a new build.
    /// Returns once the system has removed the helper: macOS refuses to register it again before that.
    func unregister() async throws
    func openApprovalSettings()
}

/// Reports when the lid closes.
public protocol LidMonitoring: AnyObject {
    func start(onClose: @escaping @Sendable () -> Void)
    func stop()
}

/// Locks the screen so a Mac that stays awake with the lid closed asks for a password when it opens.
public protocol ScreenLocking: Sendable {
    func lock()
}
