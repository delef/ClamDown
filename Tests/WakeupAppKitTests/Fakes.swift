import Foundation
@testable import WakeupAppKit

extension SystemSnapshot {
    /// On battery, plenty of charge, cool: nothing should switch Wakeup off.
    static let calm = SystemSnapshot(batteryPercent: 80, isOnBattery: true, thermal: .nominal)
}

/// Records every call and returns scripted answers. All fakes below are lock-protected
/// so they can satisfy `Sendable` protocols.
final class FakeHelper: HelperControlling, @unchecked Sendable {
    struct State {
        var enableCalls: [Bool] = []
        var lowPowerCalls: [Bool] = []
        var disableCount = 0
        var heartbeatCount = 0
        var enabled = false
        var enableError: Error?
        var disableError: Error?
        var lowPowerError: Error?
        var heartbeatResult: Result<Bool, Error> = .success(true)
    }

    private let lock = NSLock()
    private var state = State()

    func with<T>(_ body: (inout State) throws -> T) rethrows -> T { try lock.withLock { try body(&state) } }

    var enableCalls: [Bool] { with { $0.enableCalls } }
    var lowPowerCalls: [Bool] { with { $0.lowPowerCalls } }
    var disableCount: Int { with { $0.disableCount } }
    var heartbeatCount: Int { with { $0.heartbeatCount } }

    func enable(lowPowerOnBattery: Bool) async throws {
        try with { state in
            state.enableCalls.append(lowPowerOnBattery)
            if let error = state.enableError { throw error }
            state.enabled = true
        }
    }

    func disable() async throws {
        try with { state in
            state.disableCount += 1
            if let error = state.disableError { throw error }
            state.enabled = false
        }
    }

    func setLowPowerOnBattery(_ on: Bool) async throws {
        try with { state in
            state.lowPowerCalls.append(on)
            if let error = state.lowPowerError { throw error }
        }
    }

    func heartbeat() async throws -> Bool {
        try with { state in
            state.heartbeatCount += 1
            return try state.heartbeatResult.get()
        }
    }

    func isEnabled() async throws -> Bool { with { $0.enabled } }
}

/// Answers `availability()` from a script, repeating the last entry once the script runs out.
final class FakeRegistrar: HelperRegistering, @unchecked Sendable {
    private let lock = NSLock()
    private let script: [HelperAvailability]
    private var index = 0
    private var registers = 0
    private var approvals = 0
    var registerError: Error?

    init(_ script: [HelperAvailability] = [.ready]) { self.script = script }

    var registerCount: Int { lock.withLock { registers } }
    var openApprovalCount: Int { lock.withLock { approvals } }

    func availability() -> HelperAvailability {
        lock.withLock {
            defer { index += 1 }
            return script[min(index, script.count - 1)]
        }
    }

    func register() throws {
        try lock.withLock {
            registers += 1
            if let registerError { throw registerError }
        }
    }

    func openApprovalSettings() { lock.withLock { approvals += 1 } }
}

final class FakeMonitor: SystemMonitoring {
    var current: SystemSnapshot
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var onChange: (@Sendable () -> Void)?

    init(_ snapshot: SystemSnapshot = .calm) { current = snapshot }

    func snapshot() -> SystemSnapshot { current }
    func start(onChange: @escaping @Sendable () -> Void) {
        startCount += 1
        self.onChange = onChange
    }
    func stop() { stopCount += 1 }
}

final class FakeNotifier: Notifying, @unchecked Sendable {
    struct Posted: Equatable {
        let title: String
        let body: String
    }

    private let lock = NSLock()
    private var items: [Posted] = []

    var posted: [Posted] { lock.withLock { items } }

    func post(title: String, body: String) {
        lock.withLock { items.append(Posted(title: title, body: body)) }
    }
}

final class FakeActivity: ProcessActivityHolding {
    private(set) var beginCount = 0
    private(set) var endCount = 0

    func begin() { beginCount += 1 }
    func end() { endCount += 1 }
}

final class FakeSettingsStore: SettingsStoring {
    var stored: Settings
    private(set) var saved: [Settings] = []

    init(_ settings: Settings = Settings()) { stored = settings }

    func load() -> Settings { stored }
    func save(_ settings: Settings) {
        stored = settings
        saved.append(settings)
    }
}
