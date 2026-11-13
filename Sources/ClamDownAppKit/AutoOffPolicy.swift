public enum AutoOffReason: Equatable, Sendable {
    case batteryLow(percent: Int)
    case thermal(ThermalLevel)
    case unplugged
    case timerEnded

    /// True for the reasons that protect the Mac itself. Only these may put it to sleep.
    public var isProtective: Bool {
        switch self {
        case .batteryLow, .thermal: true
        case .unplugged, .timerEnded: false
        }
    }

    /// Short phrase used in notifications and status lines.
    public var summary: String {
        switch self {
        case .batteryLow(let percent): "battery at \(percent)%"
        case .thermal(let level): "Mac is hot (\(level.name))"
        case .unplugged: "power adapter unplugged"
        case .timerEnded: "timer ended"
        }
    }
}

public enum AutoOffPolicy {
    /// Why ClamDown must be off (or must not turn on) for this snapshot, or nil when it may run.
    /// Thermal is checked first because it is the more urgent reason.
    public static func reason(for snapshot: SystemSnapshot, settings: Settings) -> AutoOffReason? {
        if let limit = settings.thermalCutoff.level, snapshot.thermal >= limit {
            return .thermal(snapshot.thermal)
        }
        if settings.turnOffWhenUnplugged, snapshot.isOnBattery {
            return .unplugged
        }
        if settings.batteryCutoffEnabled, snapshot.isOnBattery, let percent = snapshot.batteryPercent,
           percent <= settings.batteryCutoffPercent {
            return .batteryLow(percent: percent)
        }
        return nil
    }
}
