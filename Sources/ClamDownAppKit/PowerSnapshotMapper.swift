public enum PowerSnapshotMapper {
    /// The `Temperature` of the `AppleSmartBattery` IORegistry entry, in hundredths of °C, as °C.
    /// Nil when it is missing or not a believable battery temperature.
    public static func batteryCelsius(hundredths: Int?) -> Double? {
        guard let hundredths else { return nil }
        let celsius = Double(hundredths) / 100
        return celsius > 0 && celsius < 130 ? celsius : nil
    }

    /// Turns IOKit power-source data into the two facts ClamDown needs.
    /// - Parameters:
    ///   - providingSource: `IOPSGetProvidingPowerSourceType`, e.g. "Battery Power" or "AC Power".
    ///   - descriptions: one dictionary per power source from `IOPSGetPowerSourceDescription`.
    /// - Returns: the internal battery's charge in percent (nil when there is none) and whether the Mac runs on battery.
    public static func map(providingSource: String?, descriptions: [[String: Any]]) -> (batteryPercent: Int?, isOnBattery: Bool) {
        let isOnBattery = providingSource == "Battery Power"
        guard let battery = descriptions.first(where: { $0["Type"] as? String == "InternalBattery" }),
              let current = battery["Current Capacity"] as? Int,
              let maximum = battery["Max Capacity"] as? Int,
              maximum > 0 else {
            return (nil, isOnBattery)
        }
        let percent = Int((Double(current) / Double(maximum) * 100).rounded())
        return (min(max(percent, 0), 100), isOnBattery)
    }
}
