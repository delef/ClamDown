import Foundation
@testable import ClamDownHelperKit

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

final class FakeStore: SavedStateStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var state: SavedState?
    private var loadFails = false

    init(initial: SavedState? = nil, loadFails: Bool = false) {
        self.state = initial
        self.loadFails = loadFails
    }

    var saved: SavedState? { lock.withLock { state } }

    func load() throws -> SavedState? {
        try lock.withLock {
            if loadFails { throw FakeFailure() }
            return state
        }
    }

    func save(_ newState: SavedState) throws { lock.withLock { state = newState } }
    func clear() throws { lock.withLock { state = nil } }
}
