import Foundation
import os
import ClamDownHelperKit
import ClamDownShared

/// The helper's journal on a real Mac: changes and failures go to the system log, subsystem `app.clamdown`, one
/// category per topic, at levels macOS keeps on disk for days (`notice`, `error`); fan ticks go to `FanTraceFile`.
/// Everything is public: temperatures, speeds and error codes say nothing about the user.
final class SystemJournal: HelperJournal, @unchecked Sendable {
    private let trace: FanTraceFile
    private let lock = NSLock()
    /// The last trace failure written down, so a disk that keeps refusing writes one line, not one per tick.
    private var traceProblem: String?

    init(trace: FanTraceFile) {
        self.trace = trace
    }

    func change(_ topic: JournalTopic, _ message: String) {
        Self.logger(topic).notice("\(message, privacy: .public)")
    }

    func failure(_ topic: JournalTopic, _ message: String) {
        Self.logger(topic).error("\(message, privacy: .public)")
    }

    func record(_ tick: FanTick) {
        let problem: String?
        do {
            try trace.append(tick, at: Date())
            problem = nil
        } catch {
            problem = "fan trace: \(error)"
        }
        lock.lock()
        let isNew = problem != nil && problem != traceProblem
        traceProblem = problem
        lock.unlock()
        if isNew, let problem { failure(.storage, problem) }
    }

    private static func logger(_ topic: JournalTopic) -> Logger {
        Logger(subsystem: Identifiers.logSubsystem, category: topic.rawValue)
    }
}
