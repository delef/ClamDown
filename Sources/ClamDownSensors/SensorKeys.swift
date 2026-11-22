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

    /// The die-zone temperature of each chip that the SMC's own fan controller steers by: `Tf14` for the CPU and
    /// `Tf24` for the GPU, each compared with its setpoint (`Tf16`, `Tf26`, about 76–82 °C on an M3 Pro). A zone
    /// runs about 14 °C under the hottest core and moves far less when a few cores spike: measured on the owner's
    /// M3 Pro on 2026-11-22, 0.38 °C a second on average against 1.88 °C for the hottest core. The `Tf` family is
    /// otherwise the controller's gains and flags, and Apple documents none of it, so `zoneCheckKey` confirms the
    /// layout on every reading: `TCDX` is the hotter of the two zones (within 1.8 °C over 630 readings here,
    /// as GlassFan also found on its M3 Pro).
    public static let zoneKeys: [(group: SensorGroup, key: String)] = [(.cpu, "Tf14"), (.gpu, "Tf24")]
    public static let zoneCheckKey = "TCDX"
    /// How far `TCDX` may be from the hotter zone; the two are read a moment apart.
    public static let zoneCheckTolerance = 3.0

    /// The zones when the check confirms them, otherwise none: a Mac where these keys mean something else must not
    /// steer the fans by them.
    public static func confirmedZones(_ zones: [SensorGroup: Double], check: Double?) -> [SensorGroup: Double] {
        let plausible = zones.filter { CPUTemperatures.isPlausible($0.value) }
        guard plausible.count == zones.count, let hotter = plausible.values.max(), let check,
              abs(check - hotter) <= zoneCheckTolerance else { return [:] }
        return plausible
    }
}
