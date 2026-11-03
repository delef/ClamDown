public enum AutoOffReason: Equatable, Sendable {
    case batteryLow(percent: Int)
    case thermal(ThermalLevel)

    /// Short phrase used in notifications and status lines.
    public var summary: String {
        switch self {
        case .batteryLow(let percent): "battery at \(percent)%"
        case .thermal(let level): "Mac is hot (\(level.name))"
        }
    }
}

public enum AutoOffPolicy {
    /// Why Wakeup must be off (or must not turn on) for this snapshot, or nil when it may run.
    /// Thermal is checked first because it is the more urgent reason.
    public static func reason(for snapshot: SystemSnapshot, settings: Settings) -> AutoOffReason? {
        if let limit = settings.thermalCutoff.level, snapshot.thermal >= limit {
            return .thermal(snapshot.thermal)
        }
        if snapshot.isOnBattery, let percent = snapshot.batteryPercent, percent <= settings.batteryCutoffPercent {
            return .batteryLow(percent: percent)
        }
        return nil
    }
}
