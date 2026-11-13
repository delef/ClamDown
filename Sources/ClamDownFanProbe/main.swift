// A debug tool for device checks, run by hand with sudo. Never bundled with the app.
//
//   sudo .build/debug/ClamDownFanProbe step
//   sudo .build/debug/ClamDownFanProbe load <minutes>
//   sudo .build/debug/ClamDownFanProbe fullLoad <minutes>
//   sudo .build/debug/ClamDownFanProbe thermal
//
// CSV with a header row goes to stdout; progress and notes go to stderr.
// Whenever it has taken the fans, it hands them back to macOS on every way out:
// the normal end, a thrown error, SIGINT, SIGTERM and SIGHUP. SIGKILL cannot be caught.
import Foundation
import ClamDownSensors
import ClamDownShared

private let usage = """
    usage: sudo ClamDownFanProbe <command>
      step                fans to maximum for 30 s, then minimum for 30 s, then back to macOS.
                          CSV: seconds,target0,actual0[,target1,actual1...] every second.
      load <minutes>      CSV: seconds,average,hottest,thermalLevel every second. Fans untouched.
      fullLoad <minutes>  as load, with the fans held at maximum; back to macOS at the end.
      thermal             CSV: seconds,thermalLevel every second for 60 s.
    """

private enum Command {
    case step
    case load(seconds: Int)
    case fullLoad(seconds: Int)
    case thermal

    init?(_ arguments: [String]) {
        func seconds(_ text: String) -> Int? {
            guard let minutes = Double(text), minutes > 0, minutes <= 120 else { return nil }
            return max(1, Int((minutes * 60).rounded()))
        }
        switch arguments {
        case ["step"]: self = .step
        case ["thermal"]: self = .thermal
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

    var description: String {
        switch self {
        case .stopping: "stopping"
        case .noFans: "the SMC reports no fans"
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

/// Holds the fans and makes sure they go back to macOS exactly once, whichever way the probe ends.
private final class FanGuard: @unchecked Sendable {
    private let lock = NSLock()
    private let hardware: SMCFanHardware
    private var held = false
    private var stopping = false

    init(_ hardware: SMCFanHardware) { self.hardware = hardware }

    func set(_ rpms: [Double]) throws {
        try lock.withLock {
            guard !stopping else { throw ProbeError.stopping }
            // Marked before the write: a write that fails halfway may already have taken a fan.
            held = true
            try hardware.setTargets(rpms)
        }
    }

    /// Hands the fans back if they were taken, and says so. No more `set` calls succeed afterwards.
    func release(_ why: String) {
        lock.withLock {
            stopping = true
            guard held else { return }
            held = false
            do {
                try hardware.releaseFans()
                note("fans handed back to macOS (\(why)).")
            } catch {
                note("could NOT hand the fans back to macOS (\(why)): \(error). Restart the Mac to be sure.")
            }
        }
    }
}

/// Runs `body` once a second for `count` seconds, on the second from the start, and passes the time since the start.
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

private func step(_ hardware: SMCFanHardware, _ fans: FanGuard) throws {
    let reading = try hardware.read()
    guard !reading.fans.isEmpty else { throw ProbeError.noFans }
    for (index, fan) in reading.fans.enumerated() {
        note("fan \(index): now \(format(fan.rpm, 0)) rpm, minimum \(format(fan.minimum, 0)), maximum \(format(fan.maximum, 0)).")
    }
    let maximum = reading.fans.map(\.maximum)
    let minimum = reading.fans.map(\.minimum)
    emit((["seconds"] + reading.fans.indices.flatMap { ["target\($0)", "actual\($0)"] }).joined(separator: ","))
    note("fans to maximum for 30 s, then minimum for 30 s.")
    try everySecond(60) { second, elapsed in
        let targets = second < 30 ? maximum : minimum
        if second == 30 { note("now minimum.") }
        // Set every second, as the helper does each tick: macOS can take a fan back.
        try fans.set(targets)
        let now = try hardware.read()
        let columns = targets.indices.flatMap { index in
            [format(targets[index], 0), format(index < now.fans.count ? now.fans[index].rpm : nil, 0)]
        }
        emit(([format(elapsed, 1)] + columns).joined(separator: ","))
    }
}

private func load(_ seconds: Int, _ hardware: SMCFanHardware, holdingAtMaximum fans: FanGuard?) throws {
    let thermal = SystemThermalState()
    var maximum: [Double] = []
    if fans != nil {
        maximum = try hardware.read().fans.map(\.maximum)
        guard !maximum.isEmpty else { throw ProbeError.noFans }
        note("fans held at maximum (\(maximum.map { format($0, 0) }.joined(separator: "/")) rpm) for \(seconds) s.")
    } else {
        note("fans untouched; reading for \(seconds) s.")
    }
    emit("seconds,average,hottest,thermalLevel")
    try everySecond(seconds) { second, elapsed in
        if let fans { try fans.set(maximum) }
        let reading = try hardware.read()
        let level = thermal.thermalLevel().name
        emit([format(elapsed, 1), format(reading.cpuTemperature, 1), format(reading.hottestCPUTemperature, 1), level]
            .joined(separator: ","))
        if second % 30 == 0 {
            note("\(second)/\(seconds) s: average \(format(reading.cpuTemperature, 1)) °C, hottest "
                + "\(format(reading.hottestCPUTemperature, 1)) °C, \(level), fans \(fanSummary(reading)).")
        }
    }
}

private func thermal() {
    let thermal = SystemThermalState()
    note("reading ProcessInfo.thermalState as uid \(getuid()) for 60 s.")
    emit("seconds,thermalLevel")
    everySecond(60) { second, elapsed in
        let level = thermal.thermalLevel().name
        emit("\(format(elapsed, 1)),\(level)")
        if second % 10 == 0 { note("\(second)/60 s: \(level).") }
    }
}

private func run() -> Never {
    guard let command = Command(Array(CommandLine.arguments.dropFirst())) else {
        writeLine(usage, to: STDERR_FILENO)
        exit(2)
    }
    guard getuid() == 0 else {
        note("run it with sudo: it drives the fans through the SMC and must see what a root daemon sees.")
        exit(1)
    }
    guard let hardware = SMCFanHardware() else {
        note("cannot open the SMC.")
        exit(1)
    }
    let fans = FanGuard(hardware)

    // A reader that goes away must not kill the probe before it hands the fans back.
    signal(SIGPIPE, SIG_IGN)
    let signalQueue = DispatchQueue(label: "ClamDownFanProbe.signals")
    let signalSources = [(SIGINT, "SIGINT"), (SIGTERM, "SIGTERM"), (SIGHUP, "SIGHUP")].map { number, name in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: signalQueue)
        source.setEventHandler {
            note("\(name) received.")
            fans.release(name)
            exit(128 + number)
        }
        source.resume()
        return source
    }

    // A dispatch source is cancelled once released, so the sources are kept alive for the whole run.
    withExtendedLifetime(signalSources) {
        do {
            switch command {
            case .step, .fullLoad:
                guard hardware.supportsControl else {
                    note(FanHardwareError.unsupported.description)
                    exit(1)
                }
                note("ClamDown's own fan control must be off while this runs, or the two fight over the fans.")
            case .load, .thermal: break
            }
            switch command {
            case .step: try step(hardware, fans)
            case .load(let seconds): try load(seconds, hardware, holdingAtMaximum: nil)
            case .fullLoad(let seconds): try load(seconds, hardware, holdingAtMaximum: fans)
            case .thermal: thermal()
            }
        } catch {
            note("failed: \(error)")
            fans.release("after an error")
            exit(1)
        }
        fans.release("done")
    }
    note("done.")
    exit(0)
}

run()
