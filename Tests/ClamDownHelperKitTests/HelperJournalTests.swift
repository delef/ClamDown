import Foundation
import Testing
import ClamDownShared
import ClamDownSensors
@testable import ClamDownHelperKit

/// The journal is how a problem on a user's Mac is traced afterwards: every change to the mode and the fans must be
/// there, in order, with its cause. Before it, a look at a Mac could see the fans now but not why they had run.
@Suite struct HelperJournalTests {
    private let t0 = SuspendingClock.now
    private func at(_ seconds: Int) -> SuspendingClock.Instant { t0.advanced(by: .seconds(seconds)) }

    @Test func aSessionLeavesEachChangeWithItsCause() async throws {
        let fans = FakeFans(temperature: 40)
        fans.followsTargets = true
        fans.set(group: .battery, 46)
        let journal = RecordingJournal()
        let core = HelperCore(runner: FakeRunner(), store: FakeStore(), originals: FakeOriginalStore(), fans: fans,
                              lid: FakeLid(state: LidState(closed: true, closingCausesSleep: true)), idle: FakeIdle(),
                              watchdogTimeout: .seconds(90), fanStepDown: 150, journal: journal)
        try await core.enable(lowPowerOnBattery: false, now: at(0))
        try await core.setFanPolicy(FanPolicy(points: [.init(temperature: 60, speed: 0), .init(temperature: 80, speed: 100)],
                                              onlyWhenLidClosed: true), now: at(0))
        fans.set(group: .battery, 42)
        await core.updateFans(now: at(3))
        await core.updateFans(now: at(36))
        fans.failSet()
        await core.updateFans(now: at(39))
        _ = await core.checkWatchdog(now: at(91))

        #expect(journal.entries == [
            "mode change: on; before it sleep disabled was false, Low Power Mode on battery false; "
                + "Low Power Mode on battery while on: false",
            "fans change: policy: 60 °C 0 %, 80 °C 100 %; only with the lid closed",
            "fans change: took the fans from macOS at 46.0 °C followed, 100 % of their range",
            "fans change: full speed: the battery is hot (46.0 °C)",
            "fans change: full speed ended: back to the curve at 42.0 °C followed",
            "fans failure: Could not set the fan speed: FakeFailure() → macOS drives the fans; control is retrying",
            "fans change: handed the fans back to macOS because of a fault",
            "mode change: off: no heartbeat from the app for 90.0 seconds; sleep disabled back to false, "
                + "Low Power Mode on battery back to false",
            "sleep change: asked macOS to sleep the abandoned Mac (request 1)",
        ])
        // Every tick that read the sensors is in the trace, the failed one too.
        #expect(journal.ticks.map(\.outcome) == [.set, .set, .set, .fault])
    }

    /// The watchdog retries a failed switch-off, and every tick retries a failed hand-back: each is written once,
    /// not every three seconds.
    @Test func aFailureRetriedOnEveryTickIsWrittenOnce() async throws {
        let fans = FakeFans(temperature: 70)
        fans.followsTargets = true
        let runner = FakeRunner()
        let journal = RecordingJournal()
        let core = HelperCore(runner: runner, store: FakeStore(), originals: FakeOriginalStore(), fans: fans,
                              watchdogTimeout: .seconds(90), journal: journal)
        try await core.enable(lowPowerOnBattery: false, now: at(0))
        try await core.setFanPolicy(FanPolicy(points: [.init(temperature: 60, speed: 50)], onlyWhenLidClosed: true), now: at(0))
        runner.fail(.setSleepDisabled(false))
        fans.failRelease()
        fans.set(lidClosed: false)
        for tick in 0..<3 {
            _ = await core.checkWatchdog(now: at(91 + 3 * tick))
            await core.updateFans(now: at(91 + 3 * tick))
        }
        #expect(journal.entries.filter { $0.hasPrefix("mode failure: could not switch off") }.count == 1)
        #expect(journal.entries.filter { $0.contains("Could not hand the fans back") }.count == 1)
    }
}
