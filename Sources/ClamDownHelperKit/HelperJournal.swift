import Foundation
import ClamDownShared
import ClamDownSensors

/// What the helper writes down, so a problem on a user's Mac can be traced afterwards: each change it makes, with its
/// cause and the values behind it, each failure, and every fan tick's readings and decision. The process wires the
/// live one (the system log and `FanTraceFile`); tests leave it out.
public protocol HelperJournal: Sendable {
    /// Something changed: the mode, who drives the fans, a full-speed override. Rare, so each is kept.
    func change(_ topic: JournalTopic, _ message: String)
    /// Something failed, and what the helper does about it.
    func failure(_ topic: JournalTopic, _ message: String)
    /// One fan tick that read the sensors.
    func record(_ tick: FanTick)
}

/// The part of the helper a journal entry is about; the system log's category.
public enum JournalTopic: String, Sendable {
    /// The helper process: start, refusal to serve, exit.
    case process
    /// The mode: switch-on and switch-off, with who asked.
    case mode
    /// Who drives the fans, the policy, faults and full-speed overrides.
    case fans
    /// Putting back what an earlier run left behind.
    case recovery
    /// The sleep the watchdog owes an abandoned Mac.
    case sleep
    /// The files the helper keeps its state in.
    case storage
}

/// One fan tick as `FanTraceFile` writes it: what the sensors read, what the rules made of it, and what the helper
/// did. The trace replays as a sensor recording (`SensorTraceTests`), so a complaint becomes a test.
public struct FanTick: Equatable, Sendable {
    /// What the tick did with the fans.
    public enum Outcome: String, Sendable {
        /// The targets were written.
        case set
        /// The lid is open and the fans follow ClamDown only with it closed: macOS has them.
        case lidOpen = "lid-open"
        /// A fault happened earlier and the retry waits: macOS has them.
        case waiting
        /// This tick found a fault and handed the fans back.
        case fault
    }

    public var groups: [SensorGroup: Double]
    public var zones: [SensorGroup: Double]
    public var hottestCore: Double?
    public var cpuAverage: Double?
    public var lidClosed: Bool?
    public var fanRPM: [Double]
    /// The temperature the curve and the floor followed. Nil when nothing could be read.
    public var followed: Double?
    /// The speed the rules asked for, in percent of each fan's range. Nil when the tick did not get that far.
    public var percent: Double?
    public var override: FanOverride?
    /// The targets written, in fan order. Nil when none were.
    public var targets: [Double]?
    public var outcome: Outcome

    public init(reading: HardwareReading, followed: Double?, outcome: Outcome) {
        groups = reading.groupTemperatures
        zones = reading.zoneTemperatures
        hottestCore = reading.hottestCPUTemperature
        cpuAverage = reading.cpuTemperature
        lidClosed = reading.lidClosed
        fanRPM = reading.fans.map(\.rpm)
        self.followed = followed
        self.outcome = outcome
    }
}
