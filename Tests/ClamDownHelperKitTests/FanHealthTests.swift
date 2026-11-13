import ClamDownShared
import Foundation
import Testing
@testable import ClamDownHelperKit

@Suite struct FanHealthTests {
    private let t0 = SuspendingClock.now

    private func at(_ seconds: Int) -> SuspendingClock.Instant { t0.advanced(by: .seconds(seconds)) }

    /// Calls `tickHeld` every 3 seconds from `from` to `to`, both included.
    private func hold(_ health: inout FanHealth, from: Int, to: Int) {
        for second in stride(from: from, through: to, by: 3) { health.tickHeld(now: at(second)) }
    }

    @Test func startsControlling() {
        let health = FanHealth()
        #expect(health.state == .controlling)
        #expect(health.reason == nil)
        #expect(health.mayTry(now: at(0)))
    }

    @Test func failedWriteRetriesAfterThirtySeconds() {
        var health = FanHealth()
        health.fault("write failed", now: at(0))
        #expect(health.state == .retrying)
        #expect(health.reason == "write failed")
        #expect(!health.mayTry(now: at(29)))
        #expect(health.mayTry(now: at(30)))
    }

    @Test func aHeldRetryControlsAgain() {
        var health = FanHealth()
        health.fault("write failed", now: at(0))
        health.tickHeld(now: at(30))
        #expect(health.state == .controlling)
        #expect(health.reason == nil)
    }

    @Test func threeFaultsInARowStop() {
        var health = FanHealth()
        health.fault("a", now: at(0))
        health.fault("b", now: at(30))
        #expect(health.state == .retrying)
        health.fault("c", now: at(60))
        #expect(health.state == .stopped)
        #expect(health.reason == "c")
    }

    /// A fan that takes the write and lags again fifteen seconds later still counts.
    @Test func shortHoldsDoNotResetTheCount() {
        var health = FanHealth()
        health.fault("lag", now: at(0))
        hold(&health, from: 30, to: 45)
        health.fault("lag", now: at(48))
        hold(&health, from: 78, to: 93)
        health.fault("lag", now: at(96))
        #expect(health.state == .stopped)
    }

    @Test func sixtyQuietSecondsResetTheCount() {
        var health = FanHealth()
        health.fault("a", now: at(0))
        hold(&health, from: 30, to: 90)
        health.fault("b", now: at(93))
        health.fault("c", now: at(123))
        #expect(health.state == .retrying)
    }

    @Test func fiftySevenQuietSecondsDoNot() {
        var health = FanHealth()
        health.fault("a", now: at(0))
        hold(&health, from: 30, to: 87)
        health.fault("b", now: at(90))
        health.fault("c", now: at(120))
        #expect(health.state == .stopped)
    }

    @Test func stoppedTriesEveryFiveMinutes() {
        var health = FanHealth()
        for second in [-60, -30, 0] { health.fault("x", now: at(second)) }
        #expect(health.state == .stopped)
        #expect(!health.mayTry(now: at(299)))
        #expect(health.mayTry(now: at(300)))
        hold(&health, from: 300, to: 357)
        #expect(health.state == .stopped)
        health.tickHeld(now: at(360))
        #expect(health.state == .controlling)
        #expect(health.reason == nil)
    }

    @Test func aFailedTryWhileStoppedWaitsAnotherFiveMinutes() {
        var health = FanHealth()
        for second in [-60, -30, 0] { health.fault("x", now: at(second)) }
        health.fault("y", now: at(300))
        #expect(health.state == .stopped)
        #expect(!health.mayTry(now: at(599)))
        #expect(health.mayTry(now: at(600)))
    }

    @Test func restartStartsAfresh() {
        var health = FanHealth()
        for second in [0, 30, 60] { health.fault("x", now: at(second)) }
        health.restart()
        #expect(health.state == .controlling)
        #expect(health.reason == nil)
        #expect(health.mayTry(now: at(61)))
        health.fault("y", now: at(61))
        #expect(health.state == .retrying)
    }

    /// A pause (lid open, fan control off) is not control without a fault, so it does not count toward the quiet minute.
    @Test func aPauseRestartsTheQuietMinute() {
        var health = FanHealth()
        health.fault("a", now: at(0))
        hold(&health, from: 30, to: 45)
        health.pause()
        hold(&health, from: 300, to: 345)
        health.fault("b", now: at(348))
        health.fault("c", now: at(378))
        #expect(health.state == .stopped)
    }

    /// `SuspendingClock` stands still while the Mac sleeps; a gap only means ticks were missed. One retry follows.
    @Test func sleepGapDoesNotDoubleFire() {
        var health = FanHealth()
        health.fault("a", now: at(0))
        #expect(health.mayTry(now: at(3 * 3600)))
        health.tickHeld(now: at(3 * 3600))
        #expect(health.state == .controlling)
        health.fault("b", now: at(3 * 3600 + 3))
        #expect(health.state == .retrying)  // the count was not reset by the gap
        #expect(!health.mayTry(now: at(3 * 3600 + 6)))
    }
}

@Suite struct LagWatchTests {
    private let fan = FanReading(rpm: 1000, minimum: 1000, maximum: 5000)

    private func fan(rpm: Double) -> FanReading { FanReading(rpm: rpm, minimum: 1000, maximum: 5000) }

    @Test func laggingFanForFiveTicksIsAFault() {
        var watch = LagWatch()
        for _ in 1...4 { #expect(watch.update(targets: [5000], fans: [fan]) == nil) }
        #expect(watch.update(targets: [5000], fans: [fan]) == 0)
    }

    @Test func reportsWhichFanLags() {
        var watch = LagWatch()
        for _ in 1...4 { _ = watch.update(targets: [5000, 5000], fans: [fan(rpm: 5000), fan(rpm: 1000)]) }
        #expect(watch.update(targets: [5000, 5000], fans: [fan(rpm: 5000), fan(rpm: 1000)]) == 1)
    }

    @Test func spinningUpFanIsLeftAlone() {
        var watch = LagWatch()
        for rpm in [1000.0, 1800, 2900, 4300, 4900, 5000, 5000, 5000] {
            #expect(watch.update(targets: [5000], fans: [fan(rpm: rpm)]) == nil)
        }
    }

    @Test func withinTwentyPercentIsNotLagging() {
        var watch = LagWatch()
        for _ in 1...20 { #expect(watch.update(targets: [5000], fans: [fan(rpm: 4200)]) == nil) }
    }

    @Test func oneGoodTickRestartsTheCount() {
        var watch = LagWatch()
        for _ in 1...4 { _ = watch.update(targets: [5000], fans: [fan]) }
        _ = watch.update(targets: [5000], fans: [fan(rpm: 5000)])
        for _ in 1...4 { #expect(watch.update(targets: [5000], fans: [fan]) == nil) }
        #expect(watch.update(targets: [5000], fans: [fan]) == 0)
    }

    @Test func fasterThanTargetIsFine() {
        var watch = LagWatch()
        for _ in 1...20 { #expect(watch.update(targets: [1000], fans: [fan(rpm: 5000)]) == nil) }
    }

    @Test func fanWithNoRangeIsSkipped() {
        var watch = LagWatch()
        let fixed = FanReading(rpm: 0, minimum: 2000, maximum: 2000)
        let inverted = FanReading(rpm: 0, minimum: 3000, maximum: 2000)
        for _ in 1...20 { #expect(watch.update(targets: [2000, 3000], fans: [fixed, inverted]) == nil) }
    }

    @Test func fanAtZeroWithZeroTargetIsFine() {
        var watch = LagWatch()
        let still = FanReading(rpm: 0, minimum: 0, maximum: 5000)
        for _ in 1...20 { #expect(watch.update(targets: [0], fans: [still]) == nil) }
    }

    @Test func mismatchedListsAreNotJudged() {
        var watch = LagWatch()
        for _ in 1...20 { #expect(watch.update(targets: [5000, 5000], fans: [fan]) == nil) }
    }
}
