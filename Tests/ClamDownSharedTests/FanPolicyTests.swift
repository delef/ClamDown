import Testing
import ClamDownShared

@Suite struct FanPolicyTests {
    @Test func clampsBothPointsIntoRange() {
        let policy = FanPolicy(mode: .curve, startTemperature: 10, fullSpeedTemperature: 200, onlyWhenLidClosed: true).clamped()
        #expect(policy.startTemperature == 40 && policy.fullSpeedTemperature == 100)
    }

    @Test func keepsFullSpeedAboveStart() {
        let policy = FanPolicy(mode: .curve, startTemperature: 80, fullSpeedTemperature: 70, onlyWhenLidClosed: true).clamped()
        #expect(policy.startTemperature == 80 && policy.fullSpeedTemperature == 85)
    }
}
