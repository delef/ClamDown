import Foundation
import ClamDownShared

public enum AutoOffReason: Equatable, Sendable {
    case batteryLow(percent: Int)
    case thermal(ThermalLevel)
    /// The battery has been at or above the limit for the hold time; whole °C.
    case batteryHot(celsius: Int)
    case unplugged
    case timerEnded

    /// True for the reasons that protect the Mac itself. Only these may put it to sleep.
    public var isProtective: Bool {
        switch self {
        case .batteryLow, .thermal, .batteryHot: true
        case .unplugged, .timerEnded: false
        }
    }

    /// Short phrase used in notifications and status lines.
    public var summary: String {
        switch self {
        case .batteryLow(let percent): String(localized: "battery at \(percent)%")
        case .thermal(let level): String(localized: "Mac is hot (\(level.name))")
        case .batteryHot(let celsius): String(localized: "battery is hot (\(celsius) \u{00B0}C)")
        case .unplugged: String(localized: "power adapter unplugged")
        case .timerEnded: String(localized: "timer ended")
        }
    }
}

public enum AutoOffPolicy {
    /// Why ClamDown must be off (or must not turn on) for this snapshot, or nil when it may run.
    /// `batteryHeat` is what `BatteryHeatWatch` said for the same snapshot: the hold time needs state, this does not.
    /// Thermal is checked first because it is the more urgent reason, then a hot battery.
    public static func reason(for snapshot: SystemSnapshot, settings: Settings,
                              batteryHeat: AutoOffReason? = nil) -> AutoOffReason? {
        if let limit = settings.thermalCutoff.level, snapshot.thermal >= limit {
            return .thermal(snapshot.thermal)
        }
        if let batteryHeat {
            return batteryHeat
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

/// Decides when a hot battery switches ClamDown off: at or above the limit for the whole hold time.
/// A reading below the limit, a missing one or the setting off starts the hold again.
public struct BatteryHeatWatch: Sendable {
    /// When the current run of hot readings began.
    private var hotSince: Date?

    public init() {}

    /// Takes one snapshot; returns the reason once the battery has stayed hot for the hold time.
    public mutating func update(_ snapshot: SystemSnapshot, settings: Settings, now: Date) -> AutoOffReason? {
        guard settings.batteryHeatCutoffEnabled, let celsius = snapshot.batteryTemperature,
              celsius >= Double(settings.batteryHeatLimit) else {
            hotSince = nil
            return nil
        }
        let since = hotSince ?? now
        hotSince = since
        guard now.timeIntervalSince(since) >= settings.batteryHeatHold.duration else { return nil }
        return .batteryHot(celsius: Int(celsius.rounded()))
    }

    public mutating func reset() { hotSince = nil }
}
