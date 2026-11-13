import ClamDownSensors
import Foundation
import Testing
@testable import ClamDownHelperKit

@Suite struct WatchdogTests {
    private let t0 = SuspendingClock.now

    private static let unattended = LidState(closed: true, closingCausesSleep: true)

    private func make(prior: Bool? = false, lid: LidState? = nil) -> (HelperCore, FakeRunner, FakeStore) {
        let runner = FakeRunner(batteryLowPower: prior)
        let store = FakeStore()
        let core = HelperCore(runner: runner, store: store, lid: FakeLid(state: lid), watchdogTimeout: .seconds(90))
        return (core, runner, store)
    }

    /// The app is gone and the Mac sits closed in a bag: restore the sleep setting, then sleep at once.
    @Test func watchdogSleepsAnUnattendedMac() async throws {
        let (core, runner, _) = make(prior: nil, lid: Self.unattended)
        try await core.enable(lowPowerOnBattery: false, now: t0)
        #expect(await core.checkWatchdog(now: t0.advanced(by: .seconds(91))) == true)
        #expect(Array(runner.commands.suffix(2)) == [.setSleepDisabled(false), .sleepNow])
    }

    @Test(arguments: [
        LidState(closed: false, closingCausesSleep: true),   // someone has the lid open
        LidState(closed: true, closingCausesSleep: false),   // closed in front of an external display
        nil,                                                  // a Mac without a lid, or the state cannot be read
    ] as [LidState?])
    func watchdogLeavesAnAttendedMacAwake(lid: LidState?) async throws {
        let (core, runner, _) = make(lid: lid)
        try await core.enable(lowPowerOnBattery: false, now: t0)
        #expect(await core.checkWatchdog(now: t0.advanced(by: .seconds(91))) == true)
        #expect(!runner.commands.contains(.sleepNow))
    }

    @Test func watchdogDoesNotSleepWhenRestoreFailed() async throws {
        let (core, runner, _) = make(lid: Self.unattended)
        try await core.enable(lowPowerOnBattery: false, now: t0)
        runner.fail(.setSleepDisabled(false), times: 1)
        #expect(await core.checkWatchdog(now: t0.advanced(by: .seconds(91))) == false)
        #expect(!runner.commands.contains(.sleepNow))
        #expect(await core.checkWatchdog(now: t0.advanced(by: .seconds(101))) == true)
        #expect(runner.commands.last == .sleepNow)
    }

    /// Switching off by hand is the user's own call; only the watchdog acts for an absent user.
    @Test func manualDisableNeverSleeps() async throws {
        let (core, runner, _) = make(lid: Self.unattended)
        try await core.enable(lowPowerOnBattery: false, now: t0)
        try await core.disable()
        #expect(!runner.commands.contains(.sleepNow))
    }

    @Test func heartbeatWhenDisabledIsFalse() async {
        let (core, _, _) = make()
        #expect(await core.heartbeat() == false)
    }

    @Test func heartbeatExtendsDeadline() async throws {
        let (core, _, _) = make()
        try await core.enable(lowPowerOnBattery: true, now: t0)
        #expect(await core.heartbeat(now: t0.advanced(by: .seconds(60))))
        #expect(await core.checkWatchdog(now: t0.advanced(by: .seconds(140))) == false)  // 80 s since the last beat
        #expect(await core.checkWatchdog(now: t0.advanced(by: .seconds(151))) == true)   // 91 s
    }

    @Test func withinTimeoutDoesNothing() async throws {
        let (core, runner, _) = make()
        try await core.enable(lowPowerOnBattery: true, now: t0)
        let before = runner.commands.count
        #expect(await core.checkWatchdog(now: t0.advanced(by: .seconds(89))) == false)
        #expect(runner.commands.count == before)
        #expect(await core.isEnabled)
    }

    @Test func checkWatchdogWhenDisabledDoesNothing() async {
        let (core, runner, _) = make()
        #expect(await core.checkWatchdog(now: t0.advanced(by: .seconds(1000))) == false)
        #expect(runner.commands.isEmpty)
    }

    @Test func expiryDisablesAndRestoresLowPower() async throws {
        let (core, runner, store) = make(prior: true)
        try await core.enable(lowPowerOnBattery: true, now: t0)
        #expect(await core.checkWatchdog(now: t0.advanced(by: .seconds(91))) == true)
        #expect(Array(runner.commands.suffix(2)) == [.setSleepDisabled(false), .setBatteryLowPowerMode(true)])
        #expect(await core.isEnabled == false)
        #expect(store.saved == nil)
    }

    @Test func failedResetIsRetriedOnNextTick() async throws {
        let (core, runner, _) = make()
        try await core.enable(lowPowerOnBattery: true, now: t0)
        runner.fail(.setSleepDisabled(false), times: 1)
        #expect(await core.checkWatchdog(now: t0.advanced(by: .seconds(91))) == false)
        #expect(await core.isEnabled)
        #expect(await core.checkWatchdog(now: t0.advanced(by: .seconds(101))) == true)
        #expect(await core.isEnabled == false)
    }
}
