public struct SystemSnapshot: Equatable, Sendable {
    /// Charge in percent. Nil means the Mac has no battery.
    public var batteryPercent: Int?
    public var isOnBattery: Bool
    public var thermal: ThermalLevel

    public init(batteryPercent: Int?, isOnBattery: Bool, thermal: ThermalLevel) {
        self.batteryPercent = batteryPercent
        self.isOnBattery = isOnBattery
        self.thermal = thermal
    }
}
