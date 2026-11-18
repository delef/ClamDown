import Foundation

public enum PmsetError: Error, Equatable {
    case failed(status: Int32, output: String)
    /// pmset did not finish in time and was stopped. The helper's actor must never wait on it for good.
    case timedOut
}

public protocol PmsetRunning: Sendable {
    func run(_ command: PmsetCommand) throws -> String
}

public struct SystemPmsetRunner: PmsetRunning {
    public static let defaultExecutablePath = "/usr/bin/pmset"
    /// pmset answers in well under a second; one that takes this long is stuck, for example behind a busy powerd.
    public static let defaultTimeout: Duration = .seconds(10)

    private let executablePath: String
    private let timeout: Duration

    /// `executablePath` exists only so tests can point the runner at another program.
    public init(executablePath: String = SystemPmsetRunner.defaultExecutablePath, timeout: Duration = defaultTimeout) {
        self.executablePath = executablePath
        self.timeout = timeout
    }

    /// Runs pmset and waits at most `timeout`. A pmset that is still running then is stopped (SIGTERM, then SIGKILL)
    /// and the call throws `timedOut`, so a hung pmset cannot block the watchdog and the fans behind it.
    public func run(_ command: PmsetCommand) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = command.arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        let output = OutputCollector()
        pipe.fileHandleForReading.readabilityHandler = { handle in output.append(handle.availableData) }
        try process.run()
        if exited.wait(timeout: .now() + Self.interval(timeout)) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
            pipe.fileHandleForReading.readabilityHandler = nil
            throw PmsetError.timedOut
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        // Whatever the handler had not picked up yet; the process has exited, so this ends.
        output.append(pipe.fileHandleForReading.readDataToEndOfFile())
        let text = String(decoding: output.data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw PmsetError.failed(status: process.terminationStatus, output: text)
        }
        return text
    }

    private static func interval(_ duration: Duration) -> DispatchTimeInterval {
        let (seconds, attoseconds) = duration.components
        return .milliseconds(Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000))
    }
}

/// Collects a process's output from the pipe's readability handler, which runs on its own queue.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collected = Data()

    var data: Data { lock.withLock { collected } }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.withLock { collected.append(chunk) }
    }
}
