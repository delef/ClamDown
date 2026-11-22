import Foundation

/// A family of temperature sensors the curve follows. Listed in the order the Cooling page shows them;
/// when two groups are equally hot, the earlier one is named.
public enum SensorGroup: String, Codable, CaseIterable, Sendable {
    case cpu, gpu, battery, ssd, wifi, airflow

    public var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .battery: "Battery"
        case .ssd: "SSD"
        case .wifi: "Wi-Fi"
        case .airflow: "Airflow"
        }
    }

    /// The hottest of these group values and its group. Nil when there is none.
    public static func hottest(in values: [SensorGroup: Double]) -> (group: SensorGroup, celsius: Double)? {
        var best: (group: SensorGroup, celsius: Double)?
        for group in allCases {
            guard let celsius = values[group] else { continue }
            if best.map({ celsius > $0.celsius }) ?? true { best = (group, celsius) }
        }
        return best
    }
}

/// One fan as the SMC reports it. Speeds are in rpm.
public struct FanReading: Codable, Equatable, Sendable {
    public var rpm: Double
    public var minimum: Double
    public var maximum: Double
    /// The fan's number in the SMC (`F<index>…` keys). Nil when the source does not say.
    /// Targets are written by this number, so a reading that skips a fan must not be taken as in fan order.
    public var index: Int?

    public init(rpm: Double, minimum: Double, maximum: Double, index: Int? = nil) {
        self.rpm = rpm
        self.minimum = minimum
        self.maximum = maximum
        self.index = index
    }
}

/// Why the fans run at full speed whatever the curve says.
public enum FanOverride: String, Codable, Sendable {
    /// The hottest CPU core has been at its limit for a while.
    case hotCore
    /// The hottest battery sensor is hot.
    case hotBattery
    /// macOS reports the Mac's thermal level as serious or critical.
    case system
}

/// What the helper is doing with the fans.
public enum FanControlState: String, Codable, Sendable {
    /// Not asked to control them, or the lid is open with Only With Lid Closed: macOS has the fans.
    case idle
    /// ClamDown sets the fan speeds.
    case controlling
    /// A fault handed the fans back to macOS; the helper takes them again by itself soon.
    case retrying
    /// Several faults in a row: macOS has the fans and the helper only tries again now and then.
    case stopped
}

/// Temperatures and fans as the helper sees them right now.
public struct CoolingStatus: Codable, Equatable, Sendable {
    /// Average CPU temperature in °C. Nil when it cannot be read.
    public var cpuTemperature: Double?
    /// The hottest CPU core in °C. Nil when it cannot be read.
    public var hottestCPUTemperature: Double?
    public var fans: [FanReading]
    /// True while ClamDown, not macOS, sets the fan speed.
    public var isControlling: Bool
    /// Why fan control does not work, when it does not.
    public var problem: String?
    /// Why the fans run at full speed, when they do whatever the curve says.
    public var override: FanOverride?
    public var control: FanControlState
    /// The thermal level macOS reports to the helper itself. Nil when the helper does not read it.
    public var systemThermalLevel: ThermalLevel?
    /// The hottest of `groupTemperatures`, in °C: what the curve follows. Nil when no group can be read.
    public var hottestTemperature: Double?
    /// The group of `hottestTemperature`. Nil when there is none, or a later helper names a group this build does not know.
    public var hottestGroup: SensorGroup?
    /// Each group that could be read, as the curve follows it: the CPU and GPU as their die zones averaged over about
    /// half a minute (or their hottest sensor averaged over a minute on a Mac without confirmed zones), the other
    /// groups as read. An older helper, and the app reading the sensors itself, send each group's hottest sensor.
    public var groupTemperatures: [SensorGroup: Double]
    /// True while handing the fans back to macOS fails: the helper still holds them and runs them at full speed
    /// until the hand-back works. An older helper does not send it.
    public var handBackFailed: Bool

    public init(cpuTemperature: Double?, hottestCPUTemperature: Double? = nil, fans: [FanReading], isControlling: Bool,
                problem: String?, override: FanOverride? = nil, control: FanControlState = .idle,
                systemThermalLevel: ThermalLevel? = nil, hottestTemperature: Double? = nil,
                hottestGroup: SensorGroup? = nil, groupTemperatures: [SensorGroup: Double] = [:],
                handBackFailed: Bool = false) {
        self.cpuTemperature = cpuTemperature
        self.hottestCPUTemperature = hottestCPUTemperature
        self.fans = fans
        self.isControlling = isControlling
        self.problem = problem
        self.override = override
        self.control = control
        self.systemThermalLevel = systemThermalLevel
        self.hottestTemperature = hottestTemperature
        self.hottestGroup = hottestGroup
        self.groupTemperatures = groupTemperatures
        self.handBackFailed = handBackFailed
    }

    private enum CodingKeys: String, CodingKey {
        case cpuTemperature, hottestCPUTemperature, fans, isControlling, problem, override, control, systemThermalLevel
        case hottestTemperature, hottestGroup, groupTemperatures, handBackFailed
    }

    /// An older helper sends none of the newer fields, and a later one may send values this build does not know:
    /// those read as unknown instead of failing the whole status.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cpuTemperature = try container.decodeIfPresent(Double.self, forKey: .cpuTemperature)
        hottestCPUTemperature = try container.decodeIfPresent(Double.self, forKey: .hottestCPUTemperature)
        fans = try container.decode([FanReading].self, forKey: .fans)
        isControlling = try container.decode(Bool.self, forKey: .isControlling)
        problem = try container.decodeIfPresent(String.self, forKey: .problem)
        override = (try? container.decodeIfPresent(FanOverride.self, forKey: .override)) ?? nil
        control = (try? container.decodeIfPresent(FanControlState.self, forKey: .control)) ?? .idle
        systemThermalLevel = (try? container.decodeIfPresent(ThermalLevel.self, forKey: .systemThermalLevel)) ?? nil
        hottestTemperature = (try? container.decodeIfPresent(Double.self, forKey: .hottestTemperature)) ?? nil
        hottestGroup = (try? container.decodeIfPresent(SensorGroup.self, forKey: .hottestGroup)) ?? nil
        // Keyed by the group's name, so a group a later build adds is dropped instead of failing the status.
        let groups = (try? container.decodeIfPresent([String: Double].self, forKey: .groupTemperatures)) ?? nil
        groupTemperatures = Dictionary(uniqueKeysWithValues: (groups ?? [:]).compactMap { name, celsius in
            SensorGroup(rawValue: name).map { ($0, celsius) }
        })
        handBackFailed = (try? container.decodeIfPresent(Bool.self, forKey: .handBackFailed)) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(cpuTemperature, forKey: .cpuTemperature)
        try container.encodeIfPresent(hottestCPUTemperature, forKey: .hottestCPUTemperature)
        try container.encode(fans, forKey: .fans)
        try container.encode(isControlling, forKey: .isControlling)
        try container.encodeIfPresent(problem, forKey: .problem)
        try container.encodeIfPresent(override, forKey: .override)
        try container.encode(control, forKey: .control)
        try container.encodeIfPresent(systemThermalLevel, forKey: .systemThermalLevel)
        try container.encodeIfPresent(hottestTemperature, forKey: .hottestTemperature)
        try container.encodeIfPresent(hottestGroup, forKey: .hottestGroup)
        try container.encode(Dictionary(uniqueKeysWithValues: groupTemperatures.map { ($0.key.rawValue, $0.value) }),
                             forKey: .groupTemperatures)
        try container.encode(handBackFailed, forKey: .handBackFailed)
    }
}
