public enum ThermalCutoff: String, Codable, CaseIterable, Sendable {
    case fair, serious, critical, never

    /// The lowest thermal level that switches Wakeup off. Nil means never.
    public var level: ThermalLevel? {
        switch self {
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        case .never: nil
        }
    }
}

public struct Settings: Codable, Equatable, Sendable {
    public static let batteryCutoffRange = 5...50

    public var autoLowPowerOnBattery = true
    public var batteryCutoffPercent = 10
    public var thermalCutoff: ThermalCutoff = .serious
    public var launchAtLogin = false

    public init() {}

    public func clamped() -> Settings {
        var copy = self
        copy.batteryCutoffPercent = min(max(batteryCutoffPercent, Self.batteryCutoffRange.lowerBound), Self.batteryCutoffRange.upperBound)
        return copy
    }
}
