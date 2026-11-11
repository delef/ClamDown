import Foundation

/// What the app may ask the root helper to do. Nothing else is exposed.
/// A `String?` reply is an error message; nil means success.
@objc public protocol ClamDownHelperXPC {
    func enable(lowPowerOnBattery: Bool, reply: @escaping @Sendable (String?) -> Void)
    func disable(reply: @escaping @Sendable (String?) -> Void)
    func setLowPowerOnBattery(_ on: Bool, reply: @escaping @Sendable (String?) -> Void)
    /// Replies true while the mode is on. Must arrive about every 30 seconds.
    func heartbeat(reply: @escaping @Sendable (Bool) -> Void)
    /// Replies true while the mode is on.
    func status(reply: @escaping @Sendable (Bool) -> Void)
    /// `policy` is a JSON-encoded `FanPolicy`. Works only while the mode is on; switching off drops it.
    func setFanPolicy(_ policy: Data, reply: @escaping @Sendable (String?) -> Void)
    /// Replies with a JSON-encoded `CoolingStatus`, or nil when it cannot be built.
    func coolingStatus(reply: @escaping @Sendable (Data?) -> Void)
}
