import ClamDownSensors
import ClamDownShared
import Foundation
@testable import ClamDownAppKit

extension SystemSnapshot {
    /// On battery, plenty of charge, cool: nothing should switch ClamDown off.
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
        var fanPolicyCalls: [FanPolicy] = []
        var fanPolicyError: Error?
        var cooling: Result<CoolingStatus, Error> = .success(
            CoolingStatus(cpuTemperature: 70, fans: [], isControlling: false, problem: nil))
    }

    private let lock = NSLock()
    private var state = State()

    func with<T>(_ body: (inout State) throws -> T) rethrows -> T { try lock.withLock { try body(&state) } }

    var enableCalls: [Bool] { with { $0.enableCalls } }
    var lowPowerCalls: [Bool] { with { $0.lowPowerCalls } }
    var disableCount: Int { with { $0.disableCount } }
    var heartbeatCount: Int { with { $0.heartbeatCount } }
    var fanPolicyCalls: [FanPolicy] { with { $0.fanPolicyCalls } }

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

    func setFanPolicy(_ policy: FanPolicy) async throws {
        try with { state in
            state.fanPolicyCalls.append(policy)
            if let error = state.fanPolicyError { throw error }
        }
    }

    func coolingStatus() async throws -> CoolingStatus { try with { try $0.cooling.get() } }
}

/// Answers `availability()` from a script, repeating the last entry once the script runs out.
final class FakeRegistrar: HelperRegistering, @unchecked Sendable {
    private let lock = NSLock()
    private let script: [HelperAvailability]
    private var index = 0
    private var registers = 0
    private var unregisters = 0
    private var approvals = 0
    /// How many quiet pauses macOS still needs before it accepts a registration again. Zero means it accepts.
    private var pausesOwed = 0
    private var quietPauses: [Duration] = []
    var registerError: Error?
    var unregisterError: Error?
    /// How many quiet pauses a removal costs. On a real Mac it is one, unless something keeps asking in between.
    var pausesARemovalCosts = 1

    /// What macOS answers when asked to register a helper too soon after removing it.
    static let refusedAfterRemoval = HelperClientError.helper("Operation not permitted")
    /// The quiet time macOS needs after a removal, as measured on macOS 27: under half a second, over 0.3.
    static let settleTime = Duration.milliseconds(500)

    init(_ script: [HelperAvailability] = [.ready]) { self.script = script }

    var registerCount: Int { lock.withLock { registers } }
    var unregisterCount: Int { lock.withLock { unregisters } }
    var openApprovalCount: Int { lock.withLock { approvals } }
    /// Every pause the controller took, in order.
    var pauses: [Duration] { lock.withLock { quietPauses } }

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
            if pausesOwed > 0 { throw Self.refusedAfterRemoval }
        }
    }

    /// Like macOS, this returns as soon as the old helper is gone, and a registration is still refused then:
    /// the system first needs a moment in which nobody asks it to register anything.
    func unregister() async throws {
        try lock.withLock {
            unregisters += 1
            if let unregisterError { throw unregisterError }
            pausesOwed = pausesARemovalCosts
        }
        await Task.yield()
    }

    /// The controller's pause. A pause that is long enough lets the system settle.
    func pause(_ duration: Duration) {
        lock.withLock {
            quietPauses.append(duration)
            if duration >= Self.settleTime, pausesOwed > 0 { pausesOwed -= 1 }
        }
    }

    func openApprovalSettings() { lock.withLock { approvals += 1 } }
}

final class FakeInstalledHelper: InstalledHelperStoring {
    var fingerprint: String?

    init(_ fingerprint: String? = nil) { self.fingerprint = fingerprint }
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

/// Answers the permission from memory; a request moves it to `afterRequest`, like the system prompt would.
final class FakeNotificationAuthorizer: NotificationAuthorizing, @unchecked Sendable {
    private let lock = NSLock()
    private var current: NotificationPermission
    private let afterRequest: NotificationPermission
    private var requests = 0

    init(_ current: NotificationPermission = .notAsked, afterRequest: NotificationPermission = .allowed) {
        self.current = current
        self.afterRequest = afterRequest
    }

    var requestCount: Int { lock.withLock { requests } }

    /// The user changed the permission in System Settings.
    func changeInSystemSettings(to permission: NotificationPermission) {
        lock.withLock { current = permission }
    }

    func permission() async -> NotificationPermission { lock.withLock { current } }

    func requestPermission() async -> NotificationPermission {
        lock.withLock {
            requests += 1
            current = afterRequest
            return current
        }
    }
}

final class FakeSetupStore: SetupStoring {
    var completed: Bool

    init(_ completed: Bool = false) { self.completed = completed }
}

/// The lid as a test sets it. Nil stands for a Mac whose lid cannot be read.
final class FakeLidReader: LidReading, @unchecked Sendable {
    private let lock = NSLock()
    private var current: LidState?

    init(_ state: LidState? = nil) { current = state }

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

final class FakeDisplays: DisplayReading, @unchecked Sendable {
    private let lock = NSLock()
    private var current = false

    var external: Bool {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    func hasExternalDisplay() -> Bool { external }
}

/// Stands in for waiting. Records each wait and lets a test say what happens in the world meanwhile.
@MainActor
final class FakePauser {
    private(set) var waits: [Duration] = []
    var whilePaused: ((Duration) -> Void)?

    func pause(_ duration: Duration) {
        waits.append(duration)
        whilePaused?(duration)
    }
}

final class FakeSleeper: SystemSleeping, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var sleepCount: Int { lock.withLock { count } }

    func sleepNow() { lock.withLock { count += 1 } }
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
    /// When set, every save throws this error and stores nothing.
    var saveError: Error?

    init(_ settings: Settings = Settings()) { stored = settings }

    func load() -> Settings { stored }
    func save(_ settings: Settings) throws {
        if let saveError { throw saveError }
        stored = settings
        saved.append(settings)
    }
}

final class FakeLidMonitor: LidMonitoring {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var onClose: (@Sendable () -> Void)?

    func start(onClose: @escaping @Sendable () -> Void) {
        startCount += 1
        self.onClose = onClose
    }

    func stop() {
        stopCount += 1
        onClose = nil
    }
}

final class FakeScreenLocker: ScreenLocking, @unchecked Sendable {
    private let guardLock = NSLock()
    private var count = 0

    var lockCount: Int { guardLock.withLock { count } }

    func lock() { guardLock.withLock { count += 1 } }
}

/// A clock the test moves by hand.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)

    var now: Date { lock.withLock { current } }

    func advance(by seconds: TimeInterval) { lock.withLock { current += seconds } }
}

struct FakeSensors: SensorReading {
    let reading: HardwareReading

    init(_ reading: HardwareReading) { self.reading = reading }

    func read() throws -> HardwareReading { reading }
}
