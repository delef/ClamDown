import Foundation

public enum PmsetError: Error, Equatable {
    case failed(status: Int32, output: String)
}

public protocol PmsetRunning: Sendable {
    func run(_ command: PmsetCommand) throws -> String
}

public struct SystemPmsetRunner: PmsetRunning {
    public static let defaultExecutablePath = "/usr/bin/pmset"

    private let executablePath: String

    /// `executablePath` exists only so tests can point the runner at `/usr/bin/false`.
    public init(executablePath: String = SystemPmsetRunner.defaultExecutablePath) {
        self.executablePath = executablePath
    }

    public func run(_ command: PmsetCommand) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = command.arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw PmsetError.failed(status: process.terminationStatus, output: output)
        }
        return output
    }
}
