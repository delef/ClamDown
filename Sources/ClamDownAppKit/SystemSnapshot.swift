import ClamDownShared

public struct SystemSnapshot: Equatable, Sendable {
    /// Charge in percent. Nil means the Mac has no battery.
    public var batteryPercent: Int?
    public var isOnBattery: Bool
    public var thermal: ThermalLevel
    /// The battery's temperature in °C. Nil when the Mac has no battery or does not say.
    public var batteryTemperature: Double?

    public init(batteryPercent: Int?, isOnBattery: Bool, thermal: ThermalLevel, batteryTemperature: Double? = nil) {
        self.batteryPercent = batteryPercent
        self.isOnBattery = isOnBattery
        self.thermal = thermal
        self.batteryTemperature = batteryTemperature
    }
}
