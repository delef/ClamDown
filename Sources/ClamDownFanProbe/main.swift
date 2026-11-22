// A debug tool for device checks, run by hand. Never bundled with the app.
//
//   sudo .build/debug/ClamDownFanProbe step
//   sudo .build/debug/ClamDownFanProbe ftst
//   sudo .build/debug/ClamDownFanProbe load <minutes>
//   sudo .build/debug/ClamDownFanProbe fullLoad <minutes>
//        .build/debug/ClamDownFanProbe thermal [minutes]     (with or without sudo)
//        .build/debug/ClamDownFanProbe sensors [seconds]     (with or without sudo; never touches the fans)
//        .build/debug/ClamDownFanProbe keys <machine>        (with or without sudo; never touches the fans)
//   sudo .build/debug/ClamDownFanProbe release
//
// CSV with a header row goes to stdout; progress and notes go to stderr.
// Whenever it has taken the fans, it hands them back to macOS on every way out: the normal end, a thrown
// error, getting too hot, and SIGINT, SIGTERM, SIGHUP, SIGQUIT and SIGTSTP. SIGKILL cannot be caught:
// `release` is the recovery for that.
import Foundation
import ClamDownSensors
import ClamDownShared

private let probePath = ".build/debug/ClamDownFanProbe"

private let usage = """
    usage: ClamDownFanProbe <command>
      step                fans to minimum for 30 s, then maximum for 30 s, then back to macOS. Root.
                          CSV: seconds,target0,actual0[,target1,actual1...] every second.
      ftst                Ftst = 1 and no fan set to manual, for 30 s, then back to macOS. Root. Run a load meanwhile.
                          Stops early when the CPU gets hot, as step does.
                          CSV: seconds,average,hottest,actual0[,actual1...],md0[,md1...],ftst every second.
      load <minutes>      CSV: seconds,average,hottest,thermalLevel every second. Fans untouched. Root.
      fullLoad <minutes>  as load, with the fans held at maximum; back to macOS at the end. Root.
      thermal [minutes]   CSV: seconds,uid,thermalLevel every second, 5 minutes by default. Root not needed.
      sensors [seconds]   CSV: timestamp, each sensor group's hottest value, the confirmed die zones, then every key of the groups,
                          every second, 60 seconds by default. Read-only: never takes the fans. Root not needed.
      keys <machine>      JSON: type and raw bytes of every temperature and fan key, for a test fixture.
                          <machine> is free text, such as "MacBook Pro M4 Pro, macOS 27.2". Read-only. Root not needed.
      release             hands every fan back to macOS and prints each fan's mode. Root. Safe any time.
    """

/// The hottest core (or the average when it is missing) at which `step` gives up its minimum phase and `ftst` stops.
private let stepHotLimit = 95.0

private enum Command {
    case step
    case ftst
    case load(seconds: Int)
    case fullLoad(seconds: Int)
    case thermal(seconds: Int)
    case sensors(seconds: Int)
    case keys(machine: String)
    case release

    init?(_ arguments: [String]) {
        func seconds(_ text: String) -> Int? {
            guard let minutes = Double(text), minutes > 0, minutes <= 120 else { return nil }
            return max(1, Int((minutes * 60).rounded()))
        }
        switch arguments {
        case ["step"]: self = .step
        case ["ftst"]: self = .ftst
        case ["release"]: self = .release
        case ["thermal"]: self = .thermal(seconds: 300)
        case let args where args.count == 2 && args[0] == "thermal":
            guard let s = seconds(args[1]) else { return nil }
            self = .thermal(seconds: s)
        case ["sensors"]: self = .sensors(seconds: 60)
        case let args where args.count == 2 && args[0] == "keys" && !args[1].isEmpty:
            self = .keys(machine: args[1])
        case let args where args.count == 2 && args[0] == "sensors":
            guard let s = Int(args[1]), s > 0, s <= 24 * 3600 else { return nil }
            self = .sensors(seconds: s)
        case let args where args.count == 2 && args[0] == "load":
            guard let s = seconds(args[1]) else { return nil }
            self = .load(seconds: s)
        case let args where args.count == 2 && args[0] == "fullLoad":
            guard let s = seconds(args[1]) else { return nil }
            self = .fullLoad(seconds: s)
        default: return nil
        }
    }
}

private enum ProbeError: Error, CustomStringConvertible {
    case stopping
    case noFans
    case fanCountChanged(expected: Int, got: Int)
    case tooHot(Double)

    var description: String {
        switch self {
        case .stopping: "stopping"
        case .noFans: "the SMC reports no fans"
        case .fanCountChanged(let expected, let got):
            "read \(got) fans instead of \(expected); stopping so no target lands on the wrong fan"
        case .tooHot(let celsius):
            "the CPU reached \(format(celsius, 1)) °C while the fans were held low; stopped early"
        }
    }
}

/// Straight to the file descriptor: no buffering to lose on exit, and no exception when the reader is gone.
private func writeLine(_ line: String, to descriptor: Int32) {
    var text = line + "\n"
    text.withUTF8 { buffer in _ = write(descriptor, buffer.baseAddress, buffer.count) }
}

private func emit(_ line: String) { writeLine(line, to: STDOUT_FILENO) }
private func note(_ line: String) { writeLine("ClamDownFanProbe: \(line)", to: STDERR_FILENO) }

private func format(_ value: Double?, _ digits: Int) -> String {
    value.map { String(format: "%.\(digits)f", $0) } ?? ""
}

/// Holds the fans, makes sure they go back to macOS whichever way the probe ends, and owns the only exit.
private final class FanGuard: @unchecked Sendable {
    private let lock = NSLock()
    private let exitLock = NSLock()
    private let hardware: SMCFanHardware
    private var held = false
    private var stopping = false
    private var exiting = false

    init(_ hardware: SMCFanHardware) { self.hardware = hardware }

    func set(_ rpms: [Double]) throws {
        try lock.withLock {
            guard !stopping else { throw ProbeError.stopping }
            // Marked before the write: a write that fails halfway may already have taken a fan.
            held = true
            try hardware.setTargets(rpms)
        }
    }

    /// Writes `Ftst` = 1 and nothing else.
    func setTestFlag() throws {
        try lock.withLock {
            guard !stopping else { throw ProbeError.stopping }
            // Marked before the write, like `set`: `release` then clears the flag on every way out.
            held = true
            try hardware.setTestFlagOnly()
        }
    }

    /// Hands the fans back if they were taken, and says so. No more `set` calls succeed afterwards.
    private func release(_ why: String) {
        lock.withLock {
            stopping = true
            guard held else { return }
            held = false
            do {
                try hardware.releaseFans()
                note("fans handed back to macOS (\(why)).")
            } catch {
                note("could NOT hand the fans back to macOS (\(why)): \(error). Run `sudo \(probePath) release`, "
                    + "or restart the Mac.")
            }
        }
    }

    /// The single way out. The first caller hands the fans back and exits; a later caller (the main thread
    /// after a signal, or a signal after the end) waits here until that exit happens.
    func finish(_ why: String, code: Int32) -> Never {
        let first = exitLock.withLock { () -> Bool in
            defer { exiting = true }
            return !exiting
        }
        guard first else { while true { sleep(60) } }
        release(why)
        if code == 0 { note("done.") }
        // Nothing is buffered, so `_exit` loses no output and runs no exit handlers on a second thread.
        _exit(code)
    }
}

/// Runs `body` once a second for `count` seconds, on the second from the start, and passes the time since the start.
/// A slow fan takeover makes the next rows come in quick succession; `elapsed` stays the real time.
private func everySecond(_ count: Int, _ body: (_ second: Int, _ elapsed: Double) throws -> Void) rethrows {
    let clock = ContinuousClock()
    let start = clock.now
    for second in 0..<count {
        let wait = start.advanced(by: .seconds(second)) - clock.now
        if wait > .zero {
            Thread.sleep(forTimeInterval: Double(wait.components.seconds) + Double(wait.components.attoseconds) / 1e18)
        }
        let elapsed = clock.now - start
        try body(second, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
    }
}

private func fanSummary(_ reading: HardwareReading) -> String {
    reading.fans.map { format($0.rpm, 0) }.joined(separator: "/") + " rpm"
}

/// Reads the sensors and refuses a reading whose fans are not the ones the targets were made for.
private func read(_ hardware: SMCFanHardware, expectingFans count: Int) throws -> HardwareReading {
    let reading = try hardware.read()
    guard reading.fans.count == count else { throw ProbeError.fanCountChanged(expected: count, got: reading.fans.count) }
    return reading
}

/// The first reading before the fans are taken: every fan the SMC counts must be readable, or targets would shift.
private func firstReading(_ hardware: SMCFanHardware) throws -> HardwareReading {
    let smcFans = hardware.controlModes().fanModes.count
    guard smcFans > 0 else { throw ProbeError.noFans }
    return try read(hardware, expectingFans: smcFans)
}

private func step(_ hardware: SMCFanHardware, _ fans: FanGuard) throws {
    let reading = try firstReading(hardware)
    let count = reading.fans.count
    for (index, fan) in reading.fans.enumerated() {
        note("fan \(index): now \(format(fan.rpm, 0)) rpm, minimum \(format(fan.minimum, 0)), maximum \(format(fan.maximum, 0)).")
    }
    let maximum = reading.fans.map(\.maximum)
    let minimum = reading.fans.map(\.minimum)
    emit((["seconds"] + reading.fans.indices.flatMap { ["target\($0)", "actual\($0)"] }).joined(separator: ","))
    note("fans to minimum for 30 s, then maximum for 30 s. Run it at idle.")
    try everySecond(60) { second, elapsed in
        let atMinimum = second < 30
        let targets = atMinimum ? minimum : maximum
        if second == 30 { note("now maximum.") }
        // Set every second, as the helper does each tick: macOS can take a fan back.
        try fans.set(targets)
        let now = try read(hardware, expectingFans: count)
        let columns = targets.indices.flatMap { index in [format(targets[index], 0), format(now.fans[index].rpm, 0)] }
        emit(([format(elapsed, 1)] + columns).joined(separator: ","))
        if atMinimum, let celsius = now.hottestCPUTemperature ?? now.cpuTemperature, celsius >= stepHotLimit {
            throw ProbeError.tooHot(celsius)
        }
    }
}

/// What a fan does when only `Ftst` = 1 is set and every `F<n>Md` stays 0. The owner runs a load meanwhile.
private func ftst(_ hardware: SMCFanHardware, _ fans: FanGuard) throws {
    let reading = try firstReading(hardware)
    let count = reading.fans.count
    emit((["seconds", "average", "hottest"] + reading.fans.indices.map { "actual\($0)" }
        + reading.fans.indices.map { "md\($0)" } + ["ftst"]).joined(separator: ","))
    note("Ftst = 1 and no fan mode written, for 30 s. Run a load meanwhile. Stops at \(format(stepHotLimit, 0)) °C; "
        + "an early stop is itself an answer: the fans did not rise while the CPU heated.")
    try fans.setTestFlag()
    try everySecond(30) { _, elapsed in
        let now = try read(hardware, expectingFans: count)
        let modes = hardware.controlModes()
        let columns = now.fans.map { format($0.rpm, 0) } + modes.fanModes.map { format($0, 0) } + [format(modes.ftst, 0)]
        emit(([format(elapsed, 1), format(now.cpuTemperature, 1), format(now.hottestCPUTemperature, 1)] + columns)
            .joined(separator: ","))
        if let celsius = now.hottestCPUTemperature ?? now.cpuTemperature, celsius >= stepHotLimit {
            throw ProbeError.tooHot(celsius)
        }
    }
}

private func load(_ seconds: Int, _ hardware: SMCFanHardware, holdingAtMaximum fans: FanGuard?) throws {
    let thermal = SystemThermalState()
    // The fan count is only guarded when the probe sets targets; reading alone cannot hit the wrong fan.
    var maximum: [Double] = []
    if fans != nil {
        maximum = try firstReading(hardware).fans.map(\.maximum)
        note("fans held at maximum (\(maximum.map { format($0, 0) }.joined(separator: "/")) rpm) for \(seconds) s.")
    } else {
        note("fans untouched; reading for \(seconds) s.")
    }
    emit("seconds,average,hottest,thermalLevel")
    try everySecond(seconds) { second, elapsed in
        if let fans { try fans.set(maximum) }
        let reading = fans != nil ? try read(hardware, expectingFans: maximum.count) : try hardware.read()
        let level = thermal.thermalLevel().name
        emit([format(elapsed, 1), format(reading.cpuTemperature, 1), format(reading.hottestCPUTemperature, 1), level]
            .joined(separator: ","))
        if second % 30 == 0 {
            note("\(second)/\(seconds) s: average \(format(reading.cpuTemperature, 1)) °C, hottest "
                + "\(format(reading.hottestCPUTemperature, 1)) °C, \(level), fans \(fanSummary(reading)).")
        }
    }
}

/// Needs no root and no SMC, so it can run twice at once, with and without sudo, for comparison.
private func thermal(_ seconds: Int) -> Never {
    let thermal = SystemThermalState()
    let uid = getuid()
    note("reading ProcessInfo.thermalState as uid \(uid) for \(seconds) s.")
    emit("seconds,uid,thermalLevel")
    everySecond(seconds) { second, elapsed in
        let level = thermal.thermalLevel().name
        emit("\(format(elapsed, 1)),\(uid),\(level)")
        if second % 30 == 0 { note("\(second)/\(seconds) s: \(level).") }
    }
    note("done.")
    exit(0)
}

/// Every temperature the curve can follow, once a second, for checking the limits in a bag. Opens the SMC to read
/// only: no fan is taken and nothing is written, so it needs no root and leaves whatever drives the fans alone.
/// After the groups come the chips' die zones (`zone.cpu`, `zone.gpu`), empty when the check does not confirm them.
/// The key columns are the CPU and GPU keys this Mac has, then every fixed key of the table, also the ones this
/// Mac lacks (their column stays empty), so files from different Macs line up.
private func sensors(_ seconds: Int) -> Never {
    guard let hardware = SMCFanHardware() else {
        note("cannot open the SMC.")
        exit(1)
    }
    let found = hardware.sensorKeys
    let prefixed = found.filter { $0.group == .cpu || $0.group == .gpu }.flatMap(\.keys)
    let keys = prefixed + SensorKeys.fixed.flatMap(\.keys)
    let missing = SensorKeys.fixed.flatMap(\.keys).filter { key in !found.contains { $0.keys.contains(key) } }
    note("reading \(keys.count - missing.count) keys for \(seconds) s"
        + (missing.isEmpty ? "." : "; not on this Mac: \(missing.joined(separator: ", ")).")
        + " Group values leave out readings outside 10–130 °C; key columns are raw.")
    // Raw key names in the header: none contains a comma or a quote.
    let zoneGroups = SensorKeys.zoneKeys.map(\.group)
    emit((["timestamp"] + SensorGroup.allCases.map(\.rawValue) + zoneGroups.map { "zone.\($0.rawValue)" } + keys)
        .joined(separator: ","))
    let stamp = ISO8601DateFormatter()
    stamp.formatOptions = [.withInternetDateTime]
    stamp.timeZone = .current
    everySecond(seconds) { second, _ in
        let raw = hardware.readKeys(keys)
        var byGroup: [SensorGroup: [Double]] = [:]
        for (key, value) in zip(keys, raw) {
            guard let value, let group = SensorKeys.group(of: key) ?? (prefixed.contains(key) ? .cpu : nil) else { continue }
            byGroup[group, default: []].append(value)
        }
        let groups = SensorKeys.hottestByGroup(byGroup)
        let zones: [SensorGroup: Double]
        do {
            zones = try hardware.read().zoneTemperatures
        } catch {
            zones = [:]
            note("\(second) s: could not read the zones (\(error)); their columns are empty.")
        }
        emit(([stamp.string(from: Date())] + SensorGroup.allCases.map { format(groups[$0], 1) }
              + zoneGroups.map { format(zones[$0], 1) } + raw.map { format($0, 2) })
            .joined(separator: ","))
        if second % 30 == 0 {
            let summary = SensorGroup.allCases.compactMap { group in groups[group].map { "\(group.title) \(format($0, 1))" } }
            note("\(second)/\(seconds) s: \(summary.joined(separator: ", ")) °C.")
        }
    }
    note("done.")
    exit(0)
}

/// Hands every fan back to macOS and prints what the SMC says afterwards. Exits 0 only when no fan is left manual.
private func release(_ hardware: SMCFanHardware) -> Never {
    var failed = false
    do {
        try hardware.releaseFans()
    } catch {
        note("hand-back failed: \(error)")
        failed = true
    }
    if !hardware.supportsControl { note("this Mac has no manual fan control, so there was nothing to hand back.") }
    let modes = hardware.controlModes()
    emit("Ftst = \(format(modes.ftst, 0))")
    for (index, mode) in modes.fanModes.enumerated() {
        emit("F\(index)Md = \(format(mode, 0))\(mode == 1 ? " (manual)" : mode == nil ? " (unreadable)" : " (automatic)")")
    }
    if modes.ftst == 1 || modes.fanModes.contains(1) {
        note("a fan is still in manual mode.")
        failed = true
    }
    if !failed { note("every fan is with macOS.") }
    exit(failed ? 1 : 0)
}

/// Prints the key dump as JSON on stdout. Never touches the fans.
private func keys(_ machine: String) -> Never {
    guard let dump = SMCKeyDump.capture(machine: machine) else {
        note("cannot open the SMC.")
        exit(1)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(dump) else {
        note("cannot encode the dump.")
        exit(1)
    }
    emit(String(decoding: data, as: UTF8.self))
    note("\(dump.entries.count) keys.")
    exit(0)
}

private func run() -> Never {
    guard let command = Command(Array(CommandLine.arguments.dropFirst())) else {
        writeLine(usage, to: STDERR_FILENO)
        exit(2)
    }
    if case .thermal(let seconds) = command { thermal(seconds) }
    if case .sensors(let seconds) = command { sensors(seconds) }
    if case .keys(let machine) = command { keys(machine) }
    guard getuid() == 0 else {
        note("run it with sudo: it drives the fans through the SMC and must see what a root daemon sees.")
        exit(1)
    }
    guard let hardware = SMCFanHardware() else {
        note("cannot open the SMC.")
        exit(1)
    }
    if case .release = command { release(hardware) }

    var takesFans = false
    if case .step = command { takesFans = true }
    if case .ftst = command { takesFans = true }
    if case .fullLoad = command { takesFans = true }
    if takesFans {
        guard hardware.supportsControl else {
            note(FanHardwareError.unsupported.description)
            exit(1)
        }
        // Someone else holding the fans (most likely ClamDown's helper) would mix its targets into the data.
        let modes = hardware.controlModes()
        if modes.ftst == 1 || modes.fanModes.contains(1) {
            note("the fans are already in manual mode: switch off ClamDown's Fan Control (or Turn Off ClamDown) and, "
                + "if the fans are still manual, run `sudo \(probePath) release`.")
            exit(2)
        }
    }

    let fans = FanGuard(hardware)
    // A reader that goes away must not kill the probe before it hands the fans back.
    signal(SIGPIPE, SIG_IGN)
    let signalQueue = DispatchQueue(label: "ClamDownFanProbe.signals")
    let stopSignals = [(SIGINT, "SIGINT"), (SIGTERM, "SIGTERM"), (SIGHUP, "SIGHUP"), (SIGQUIT, "SIGQUIT"),
                       // Ctrl-Z would otherwise suspend the probe with the fans held.
                       (SIGTSTP, "SIGTSTP")]
    let signalSources = stopSignals.map { number, name in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: signalQueue)
        source.setEventHandler {
            note("\(name) received: handing the fans back to macOS, this can take a few seconds.")
            fans.finish(name, code: 128 + number)
        }
        source.resume()
        return source
    }

    // A dispatch source is cancelled once released, so the sources are kept alive for the whole run.
    withExtendedLifetime(signalSources) { () -> Never in
        if takesFans { note("if this probe is killed, run `sudo \(probePath) release` to hand the fans back.") }
        do {
            switch command {
            case .step: try step(hardware, fans)
            case .ftst: try ftst(hardware, fans)
            case .load(let seconds): try load(seconds, hardware, holdingAtMaximum: nil)
            case .fullLoad(let seconds): try load(seconds, hardware, holdingAtMaximum: fans)
            case .thermal, .sensors, .keys, .release: break
            }
        } catch ProbeError.stopping {
            // A signal is already handing the fans back and exiting.
            fans.finish("stopping", code: 1)
        } catch {
            note("stopped: \(error)")
            fans.finish("after an error", code: 1)
        }
        fans.finish("done", code: 0)
    }
}

run()
