import ClamDownShared

/// Which SMC temperature keys belong to which group. Only these groups count: other families (`Tf*`, `TV*`, `TR*`,
/// `Ts*`, `Th*`, `TP*`, ...) are ignored, because some are frozen on some Macs and would keep the fans high for nothing.
public enum SensorKeys {
    /// The fixed keys of the groups that are not found by prefix, in table order. A Mac may lack any of them.
    public static let fixed: [(group: SensorGroup, keys: [String])] = [
        (.battery, ["TB0T", "TB1T", "TB2T"]),
        (.ssd, ["TH0x", "TH0a", "TH0b"]),
        (.wifi, ["TW0P"]),
        (.airflow, ["TaLP", "TaRF"]),
    ]

    /// The group a key belongs to, or nil when ClamDown ignores it. CPU is `Tp*` and `Te*`, GPU is `Tg*`.
    public static func group(of key: String) -> SensorGroup? {
        if key.hasPrefix("Tp") || key.hasPrefix("Te") { return .cpu }
        if key.hasPrefix("Tg") { return .gpu }
        return fixed.first { $0.keys.contains(key) }?.group
    }

    /// Each group's hottest plausible value. A group without one is left out.
    public static func hottestByGroup(_ values: [SensorGroup: [Double]]) -> [SensorGroup: Double] {
        values.compactMapValues { $0.filter(CPUTemperatures.isPlausible).max() }
    }
}
