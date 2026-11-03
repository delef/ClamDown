import Foundation
import Testing
@testable import WakeupHelperKit

@Suite struct WatchdogTests {
    private let t0 = SuspendingClock.now

    private func make(prior: Bool? = false) -> (HelperCore, FakeRunner, FakeStore) {
        let runner = FakeRunner(batteryLowPower: prior)
        let store = FakeStore()
        return (HelperCore(runner: runner, store: store, watchdogTimeout: .seconds(90)), runner, store)
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
