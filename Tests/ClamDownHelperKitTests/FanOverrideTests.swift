import Foundation
import Testing
@testable import ClamDownHelperKit

@Suite struct HotCoreWatchTests {
    private let t0 = SuspendingClock.now

    private func at(_ seconds: Int) -> SuspendingClock.Instant { t0.advanced(by: .seconds(seconds)) }

    @Test func hotCoreNeedsTenSeconds() {
        var watch = HotCoreWatch()
        #expect(watch.update(hottest: 100, now: at(0)) == false)
        #expect(watch.update(hottest: 100, now: at(9)) == false)
        #expect(watch.update(hottest: 100, now: at(10)) == true)
    }

    @Test func aShortDipRestartsTheTenSeconds() {
        var watch = HotCoreWatch()
        _ = watch.update(hottest: 100, now: at(0))
        _ = watch.update(hottest: 99, now: at(6))
        #expect(watch.update(hottest: 100, now: at(9)) == false)
        #expect(watch.update(hottest: 100, now: at(18)) == false)
        #expect(watch.update(hottest: 100, now: at(19)) == true)
    }

    @Test func hotCoreClearsAfterThirtyCoolSeconds() {
        var watch = HotCoreWatch()
        _ = watch.update(hottest: 100, now: at(0))
        #expect(watch.update(hottest: 100, now: at(10)) == true)
        // Between 95 and 100 the override holds.
        #expect(watch.update(hottest: 97, now: at(40)) == true)
        let t1 = 50
        #expect(watch.update(hottest: 94, now: at(t1)) == true)
        #expect(watch.update(hottest: 96, now: at(t1 + 15)) == true)  // restarts the 30 s
        #expect(watch.update(hottest: 94, now: at(t1 + 20)) == true)
        #expect(watch.update(hottest: 94, now: at(t1 + 49)) == true)
        #expect(watch.update(hottest: 94, now: at(t1 + 50)) == false)
    }

    @Test func coolForExactlyThirtySecondsClears() {
        var watch = HotCoreWatch()
        _ = watch.update(hottest: 100, now: at(0))
        _ = watch.update(hottest: 100, now: at(10))
        let t1 = 20
        _ = watch.update(hottest: 94, now: at(t1))
        #expect(watch.update(hottest: 94, now: at(t1 + 29)) == true)
        #expect(watch.update(hottest: 94, now: at(t1 + 30)) == false)
    }

    @Test func missingHottestNeverTriggers() {
        var watch = HotCoreWatch()
        for second in stride(from: 0, through: 60, by: 3) {
            #expect(watch.update(hottest: nil, now: at(second)) == false)
        }
    }

    @Test func missingHottestCountsAsCool() {
        var watch = HotCoreWatch()
        _ = watch.update(hottest: 100, now: at(0))
        _ = watch.update(hottest: 100, now: at(10))
        _ = watch.update(hottest: nil, now: at(20))
        #expect(watch.update(hottest: nil, now: at(49)) == true)
        #expect(watch.update(hottest: nil, now: at(50)) == false)
    }

    /// `SuspendingClock` stands still while the Mac sleeps, so a long gap means the helper missed ticks while awake.
    /// The watch takes the two readings at face value and changes state once.
    @Test func aLongGapChangesStateOnce() {
        var watch = HotCoreWatch()
        _ = watch.update(hottest: 100, now: at(0))
        #expect(watch.update(hottest: 100, now: at(3 * 3600)) == true)
        #expect(watch.update(hottest: 100, now: at(3 * 3600 + 3)) == true)
    }
}
