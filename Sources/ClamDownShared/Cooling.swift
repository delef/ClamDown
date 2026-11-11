import Foundation

/// How ClamDown drives the fans while the mode is on.
public enum FanMode: String, Codable, CaseIterable, Sendable {
    /// macOS keeps control of the fans.
    case system
    /// Fan speed follows the CPU temperature between two points.
    case curve
    /// The fans run at their maximum speed.
    case fullSpeed
}

/// What the app asks the helper to do with the fans. The helper clamps it again before use.
public struct FanPolicy: Codable, Equatable, Sendable {
    public static let startRange = 40...90
    public static let fullSpeedRange = 50...100
    /// The full-speed point stays at least this many degrees above the start point.
    public static let minimumSpan = 5

    public var mode: FanMode
    /// At and below this CPU temperature (°C) the fans run at their minimum speed.
    public var startTemperature: Int
    /// At and above this CPU temperature (°C) the fans run at full speed.
    public var fullSpeedTemperature: Int
    /// Leaves the fans to macOS while the lid is open.
    public var onlyWhenLidClosed: Bool

    public init(mode: FanMode, startTemperature: Int, fullSpeedTemperature: Int, onlyWhenLidClosed: Bool) {
        self.mode = mode
        self.startTemperature = startTemperature
        self.fullSpeedTemperature = fullSpeedTemperature
        self.onlyWhenLidClosed = onlyWhenLidClosed
    }

    /// Keeps both points in range and the full-speed point above the start point.
    public func clamped() -> FanPolicy {
        var copy = self
        copy.startTemperature = min(max(startTemperature, Self.startRange.lowerBound), Self.startRange.upperBound)
        let full = min(max(fullSpeedTemperature, Self.fullSpeedRange.lowerBound), Self.fullSpeedRange.upperBound)
        copy.fullSpeedTemperature = max(full, copy.startTemperature + Self.minimumSpan)
        return copy
    }
}

/// One fan as the SMC reports it. Speeds are in rpm.
public struct FanReading: Codable, Equatable, Sendable {
    public var rpm: Double
    public var minimum: Double
    public var maximum: Double

    public init(rpm: Double, minimum: Double, maximum: Double) {
        self.rpm = rpm
        self.minimum = minimum
        self.maximum = maximum
    }
}

/// Temperatures and fans as the helper sees them right now.
public struct CoolingStatus: Codable, Equatable, Sendable {
    /// Average CPU temperature in °C. Nil when it cannot be read.
    public var cpuTemperature: Double?
    public var fans: [FanReading]
    /// True while ClamDown, not macOS, sets the fan speed.
    public var isControlling: Bool
    /// Why fan control does not work, when it does not.
    public var problem: String?

    public init(cpuTemperature: Double?, fans: [FanReading], isControlling: Bool, problem: String?) {
        self.cpuTemperature = cpuTemperature
        self.fans = fans
        self.isControlling = isControlling
        self.problem = problem
    }
}
