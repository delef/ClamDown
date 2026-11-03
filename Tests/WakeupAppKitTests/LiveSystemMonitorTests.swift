import Testing
@testable import WakeupAppKit

@Suite struct LiveSystemMonitorTests {
    /// Smoke test against the real IOKit on whatever Mac runs the tests.
    @Test func snapshotReadsThisMacWithoutCrashing() {
        let snapshot = LiveSystemMonitor().snapshot()
        if let percent = snapshot.batteryPercent {
            #expect((0...100).contains(percent))
        }
    }
}
