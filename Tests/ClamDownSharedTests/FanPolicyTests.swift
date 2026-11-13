import Foundation
import Testing
import ClamDownShared

@Suite struct FanPolicyTests {
    let p = FanPolicy(points: [.init(temperature: 50, speed: 0), .init(temperature: 75, speed: 100)], onlyWhenLidClosed: true)

    @Test func flatBeforeFirstPoint() { #expect(p.curveSpeed(at: 40) == 0) }
    @Test func straightBetweenPoints() { #expect(p.curveSpeed(at: 62.5) == 50) }
    @Test func flatAfterLastPoint() { #expect(p.curveSpeed(at: 99) == 100) }

    @Test func stepTakesTheHigherSpeed() {
        let s = FanPolicy(points: [.init(temperature: 60, speed: 10), .init(temperature: 60, speed: 80)], onlyWhenLidClosed: true)
        #expect(s.curveSpeed(at: 60) == 80)
    }

    @Test func floorShape() {
        #expect(SafetyFloor.speed(at: 70) == 0 && SafetyFloor.speed(at: 82.5) == 50 && SafetyFloor.speed(at: 95) == 100 && SafetyFloor.speed(at: 99) == 100)
    }

    @Test func floorWins() {
        let low = FanPolicy(points: [.init(temperature: 40, speed: 10)], onlyWhenLidClosed: true)
        #expect(low.speed(at: 90) == 80)
    }

    @Test func offIsZero() { #expect(FanPolicy(points: [], onlyWhenLidClosed: true).speed(at: 99) == 0) }

    @Test func offMeansNoPoints() {
        #expect(FanPolicy(points: [], onlyWhenLidClosed: true).isOff)
        #expect(!p.isOff)
    }

    @Test func repairBringsIntoRangeAndOrder() {
        let r = FanPolicy(points: [.init(temperature: 20, speed: -5), .init(temperature: 120, speed: 40), .init(temperature: 60, speed: 10)],
                          onlyWhenLidClosed: true).repaired()
        #expect(r.points == [.init(temperature: 40, speed: 0), .init(temperature: 100, speed: 40), .init(temperature: 100, speed: 40)])
    }

    @Test func repairKeepsNoPointsOff() {
        #expect(FanPolicy(points: [], onlyWhenLidClosed: false).repaired().isOff)
    }

    @Test func standardClamp() {
        #expect(StandardCurve.clamped(start: 90, full: 100) == (70, 95))
        #expect(StandardCurve.clamped(start: 60, full: 62) == (60, 65))
    }

    @Test func standardPointsRunFromMinimumToFull() {
        #expect(StandardCurve.points(start: 50, full: 75) == [.init(temperature: 50, speed: 0), .init(temperature: 75, speed: 100)])
    }

    @Test func policyRoundTripsAsJSON() throws {
        let decoded = try JSONDecoder().decode(FanPolicy.self, from: JSONEncoder().encode(p))
        #expect(decoded == p)
    }
}
