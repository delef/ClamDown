import Foundation

/// What launchd says about the helper's job. `SMAppService` can report a helper as allowed for half a minute while
/// launchd has failed to start it within milliseconds, so this tells a Turn On early that waiting will not help.
public enum HelperJobState: Equatable, Sendable {
    /// Nothing usable: launchd's answer could not be read or understood. The caller waits as it would without it.
    case unknown
    case running
    /// Loaded and not running yet, without a failure.
    case starting
    /// launchd tried to start the helper and could not. `reason` is launchd's own words, when it gives some.
    case spawnFailed(reason: String?)

    /// Reads the output of `launchctl print system/<label>`. The format is not documented, so only a few plain
    /// lines are used, and anything unexpected reads as `unknown`.
    public static func parse(output: String, status: Int32) -> HelperJobState {
        guard status == 0 else { return .unknown }
        var jobState: String?
        var state: String?
        var exitCode: String?
        var exitReason: String?
        for line in output.split(separator: "\n") {
            // Only the job's own lines, one tab deep; nested blocks such as a coalition have their own `state`.
            guard line.hasPrefix("\t"), !line.hasPrefix("\t\t") else { continue }
            let parts = line.dropFirst().split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "job state": jobState = value
            case "state": state = value
            case "last exit code": exitCode = value
            case "last exit reason": exitReason = value
            default: break
            }
        }
        if jobState == "spawn failed" { return .spawnFailed(reason: exitReason ?? exitCode) }
        if jobState == "running" || state == "running" { return .running }
        if state != nil { return .starting }
        return .unknown
    }
}

public protocol HelperJobReading: Sendable {
    func state() async -> HelperJobState
}

/// Asks launchd with `launchctl print`, which an ordinary user may run for a system job.
public struct LaunchctlJobReader: HelperJobReading {
    private let label: String

    public init(label: String) {
        self.label = label
    }

    public func state() async -> HelperJobState {
        let label = label
        return await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["print", "system/\(label)"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                return .unknown
            }
            // launchctl answers in milliseconds; a hung one is stopped, which also ends the read below.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
                if process.isRunning { process.terminate() }
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationReason == .exit else { return .unknown }
            return HelperJobState.parse(output: String(decoding: data, as: UTF8.self),
                                        status: process.terminationStatus)
        }.value
    }
}
