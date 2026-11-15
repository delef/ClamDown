import Foundation

/// The battery's temperature from the SMC battery keys (`TB0T`, `TB1T`, `TB2T`): the hottest plausible one.
/// Reading needs no privileges, so the app uses it when the IORegistry does not give the battery's temperature,
/// as on macOS versions whose `AppleSmartBattery` entry has no `Temperature`.
public final class SMCBatteryTemperature: @unchecked Sendable {
    private let lock = NSLock()
    private let smc: SMC
    private let keys: [String]

    /// Nil when the SMC cannot be opened or has none of the battery keys.
    public init?() {
        guard let smc = SMC() else { return nil }
        let battery = SensorKeys.fixed.first { $0.group == .battery }?.keys ?? []
        let present = battery.filter { smc.read($0)?.number != nil }
        guard !present.isEmpty else { return nil }
        self.smc = smc
        keys = present
    }

    /// In °C. Nil when no key gives a plausible value.
    public func read() -> Double? {
        lock.withLock { SensorKeys.hottestByGroup([.battery: keys.compactMap { smc.read($0)?.number }])[.battery] }
    }
}
