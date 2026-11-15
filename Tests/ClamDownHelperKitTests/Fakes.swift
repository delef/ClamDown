import Foundation
@testable import ClamDownHelperKit
import ClamDownSensors
import ClamDownShared

struct FakeFailure: Error, Equatable {}

/// Records every command and answers reads from canned text. Thread-safe so it can be `Sendable`.
final class FakeRunner: PmsetRunning, @unchecked Sendable {
    private struct Failure { let command: PmsetCommand; var remaining: Int }

    private let lock = NSLock()
    private var recorded: [PmsetCommand] = []
    private var failures: [Failure] = []
    private let batteryLowPower: Bool?
    private let sleepDisabled: Bool?

    /// `batteryLowPower` nil means the `lowpowermode` key is missing from the Battery Power section.
    /// `sleepDisabled` nil means the `SleepDisabled` line is missing from `pmset -g`.
    init(batteryLowPower: Bool? = false, sleepDisabled: Bool? = false) {
        self.batteryLowPower = batteryLowPower
        self.sleepDisabled = sleepDisabled
    }

    var commands: [PmsetCommand] { lock.withLock { recorded } }

    /// Makes the next `times` runs of `command` throw `FakeFailure`.
    func fail(_ command: PmsetCommand, times: Int = .max) {
        lock.withLock { failures.append(Failure(command: command, remaining: times)) }
    }

    func run(_ command: PmsetCommand) throws -> String {
        try lock.withLock {
            recorded.append(command)
            if let index = failures.firstIndex(where: { $0.command == command && $0.remaining > 0 }) {
                failures[index].remaining -= 1
                throw FakeFailure()
            }
            switch command {
            case .readCustom: return customOutput()
            case .readGlobal: return sleepDisabled.map { " SleepDisabled\t\t\($0 ? 1 : 0)\n" } ?? ""
            default: return ""
            }
        }
    }

    private func customOutput() -> String {
        let batteryLine = batteryLowPower.map { " lowpowermode         \($0 ? 1 : 0)\n" } ?? ""
        return "Battery Power:\n Sleep On Power Button 1\n\(batteryLine) sleep                1\n"
            + "AC Power:\n Sleep On Power Button 1\n lowpowermode         0\n sleep                0\n"
    }
}

final class FakeLid: LidReading, @unchecked Sendable {
    private let lock = NSLock()
    private var current: LidState?

    init(state: LidState?) { current = state }

    var state: LidState? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    func lid() -> LidState? { state }
}

final class FakeIdle: IdleReading, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Duration?

    /// Ten minutes by default: nobody has touched the Mac for a while.
    init(_ time: Duration? = .seconds(600)) { current = time }

    var time: Duration? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    func idleTime() -> Duration? { time }
}

/// One ordered record of what fakes were asked to do, shared between them, so a test can check the order
/// of a save and a fan write.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var events: [String] { lock.withLock { recorded } }
    func append(_ event: String) { lock.withLock { recorded.append(event) } }
}

final class FakeStore: SavedStateStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var state: SavedState?
    private var loadFails = false
    private let log: EventLog?

    init(initial: SavedState? = nil, loadFails: Bool = false, log: EventLog? = nil) {
        self.state = initial
        self.loadFails = loadFails
        self.log = log
    }

    var saved: SavedState? { lock.withLock { state } }

    func load() throws -> SavedState? {
        try lock.withLock {
            if loadFails { throw FakeFailure() }
            return state
        }
    }

    func save(_ newState: SavedState) throws {
        log?.append(newState.fansManual == true ? "save fans held" : "save fans free")
        lock.withLock { state = newState }
    }

    func clear() throws {
        log?.append("clear")
        lock.withLock { state = nil }
    }
}

/// The thermal level the test sets by hand.
final class FakeThermal: ThermalStateReading, @unchecked Sendable {
    private let lock = NSLock()
    private var current: ThermalLevel

    init(_ level: ThermalLevel = .nominal) { current = level }

    var level: ThermalLevel {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    func thermalLevel() -> ThermalLevel { level }
}

/// Fans and sensors the test sets by hand. Records every target it was given.
final class FakeFans: FanHardware, @unchecked Sendable {
    private let lock = NSLock()
    private var reading: HardwareReading
    private var setCalls: [[Double]] = []
    private var releases = 0
    private var setFails = false
    private var releaseFails = false
    private var held = false
    private var follows = false
    /// Each fan's manual mode, as `F<n>Md` would say.
    private var manual: [Bool]
    private var takeOvers = 0
    private var heldCalls: [[Double?]] = []
    private let log: EventLog?
    let supportsControl: Bool
    /// How many fans the hardware says it has. A reading can hold fewer, as when a fan's keys fail.
    let fanCount: Int

    /// `fanCount` defaults to the number of `fans`.
    init(temperature: Double? = 70, lidClosed: Bool? = true, supportsControl: Bool = true,
         fans: [FanReading] = [FanReading(rpm: 1300, minimum: 1000, maximum: 5000)], fanCount: Int? = nil,
         log: EventLog? = nil) {
        reading = HardwareReading(cpuTemperature: temperature, fans: fans, lidClosed: lidClosed)
        self.supportsControl = supportsControl
        self.fanCount = fanCount ?? fans.count
        manual = Array(repeating: false, count: fanCount ?? fans.count)
        self.log = log
    }

    /// When true, `read()` reports each fan's last target as its rpm, as fans that keep up would.
    var followsTargets: Bool {
        get { lock.withLock { follows } }
        set { lock.withLock { follows = newValue } }
    }

    var targets: [[Double]] { lock.withLock { setCalls } }
    /// What each `setTargetsIfHeld` call wrote, per fan; nil for a fan it left alone.
    var heldWrites: [[Double?]] { lock.withLock { heldCalls } }
    /// How many fans `setTargets` had to take from macOS.
    var takeOverCount: Int { lock.withLock { takeOvers } }
    /// Puts one fan in or out of manual mode, as macOS taking a fan back (or a partial release) would.
    func set(manual on: Bool, fan: Int) { lock.withLock { manual[fan] = on } }
    var releaseCount: Int { lock.withLock { releases } }
    /// True while the fake fans are under manual control.
    var isHeld: Bool { lock.withLock { held } }

    func set(temperature: Double?) { lock.withLock { reading.cpuTemperature = temperature } }
    func set(hottest: Double?) { lock.withLock { reading.hottestCPUTemperature = hottest } }
    /// Sets one sensor group's hottest value; nil removes the group, as a sensor that cannot be read.
    func set(group: SensorGroup, _ celsius: Double?) { lock.withLock { reading.groupTemperatures[group] = celsius } }
    func set(lidClosed: Bool?) { lock.withLock { reading.lidClosed = lidClosed } }
    func set(fans: [FanReading]) { lock.withLock { reading.fans = fans } }
    func failSet(_ fails: Bool = true) { lock.withLock { setFails = fails } }
    func failRelease(_ fails: Bool = true) { lock.withLock { releaseFails = fails } }

    func read() throws -> HardwareReading {
        lock.withLock {
            guard follows, let last = setCalls.last else { return reading }
            var followed = reading
            for (index, rpm) in last.prefix(followed.fans.count).enumerated() { followed.fans[index].rpm = rpm }
            return followed
        }
    }

    func setTargets(_ rpms: [Double]) throws {
        log?.append("set targets")
        try lock.withLock {
            if setFails { throw FakeFailure() }
            takeOvers += manual.filter { !$0 }.count
            manual = Array(repeating: true, count: manual.count)
            held = true
            setCalls.append(rpms)
        }
    }

    func setTargetsIfHeld(_ rpms: [Double]) throws {
        log?.append("set targets if held")
        lock.withLock {
            heldCalls.append(rpms.enumerated().map { index, rpm in index < manual.count && manual[index] ? rpm : nil })
        }
    }

    func releaseFans() throws {
        log?.append("release")
        try lock.withLock {
            releases += 1
            if releaseFails { throw FakeFailure() }
            manual = Array(repeating: false, count: manual.count)
            held = false
        }
    }
}
