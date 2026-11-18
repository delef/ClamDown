import Foundation

/// What the app may ask the root helper to do. Nothing else is exposed.
/// A `String?` reply is an error message; nil means success.
@objc public protocol ClamDownHelperXPC {
    func enable(lowPowerOnBattery: Bool, reply: @escaping @Sendable (String?) -> Void)
    func disable(reply: @escaping @Sendable (String?) -> Void)
    /// Puts back the settings recorded before ClamDown first switched on, then forgets that record.
    /// Without a record it switches the mode off, as `disable` does.
    func restoreOriginalSettings(reply: @escaping @Sendable (String?) -> Void)
    func setLowPowerOnBattery(_ on: Bool, reply: @escaping @Sendable (String?) -> Void)
    /// Replies true while the mode is on. Must arrive about every 30 seconds.
    func heartbeat(reply: @escaping @Sendable (Bool) -> Void)
    /// Replies true while the mode is on.
    func status(reply: @escaping @Sendable (Bool) -> Void)
    /// `policy` is a JSON-encoded `FanPolicy`. Switching the mode off drops it. While the mode is off it starts a
    /// fan-only session, which lasts while the same connection sends it again at least every 90 seconds;
    /// a policy with no points ends it.
    func setFanPolicy(_ policy: Data, reply: @escaping @Sendable (String?) -> Void)
    /// Replies with a JSON-encoded `CoolingStatus`, or nil when it cannot be built.
    func coolingStatus(reply: @escaping @Sendable (Data?) -> Void)
}
