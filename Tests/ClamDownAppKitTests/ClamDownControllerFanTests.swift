import ClamDownSensors
import ClamDownShared
import Foundation
import Testing
@testable import ClamDownAppKit

@MainActor @Suite struct ClamDownControllerFanTests {
    @Test func turningOnSendsTheFanPolicy() async {
        let rig = Rig()
        await rig.controller.toggle()
        #expect(rig.helper.fanPolicyCalls == [Settings().fanPolicy])
    }

    @Test func fanFailureKeepsTheModeOnAndSaysWhy() async {
        let rig = Rig()
        rig.helper.with { $0.fanPolicyError = HelperClientError.helper("no SMC") }
        await rig.controller.toggle()
        #expect(rig.controller.state == .on)
        #expect(rig.controller.notice == "Could not control the fans: no SMC")
    }

    @Test func changingFanSettingsWhileOnResendsThePolicy() async {
        let rig = Rig()
        await rig.controller.toggle()
        var settings = rig.controller.settings
        settings = FanCurveEditor.chooseAdvanced(settings)
        await rig.controller.updateSettings(settings)
        #expect(rig.helper.fanPolicyCalls == [Settings().fanPolicy, settings.fanPolicy])
        #expect(rig.helper.fanPolicyCalls.last?.points == FanCurveEditor.defaultAdvanced)
    }

    @Test func switchingFanControlOffSendsNoPoints() async {
        let rig = Rig()
        await rig.controller.toggle()
        var settings = rig.controller.settings
        settings.fanControlEnabled = false
        await rig.controller.updateSettings(settings)
        #expect(rig.helper.fanPolicyCalls.last?.isOff == true)
    }

    @Test func otherSettingsDoNotResendThePolicy() async {
        let rig = Rig()
        await rig.controller.toggle()
        var settings = rig.controller.settings
        settings.menuBarIcon = .lid
        await rig.controller.updateSettings(settings)
        #expect(rig.helper.fanPolicyCalls.count == 1)
    }

    @Test func fanSettingsWhileOffAreOnlyStored() async {
        let rig = Rig()
        var settings = rig.controller.settings
        settings.fanStartTemperature = 55
        await rig.controller.updateSettings(settings)
        #expect(rig.helper.fanPolicyCalls.isEmpty)
        await rig.controller.toggle()
        #expect(rig.helper.fanPolicyCalls.map { $0.points.first?.temperature } == [55])
    }

    @Test func coolingStatusIsNilWhenNothingCanReadTheSensors() async {
        let rig = Rig()
        rig.helper.with { $0.cooling = .failure(HelperClientError.connection("gone")) }
        #expect(await rig.controller.coolingStatus() == nil)
    }

    @Test func withoutTheHelperTheAppReadsTheSensorsItself() async {
        let fan = FanReading(rpm: 1400, minimum: 1300, maximum: 5000)
        let rig = Rig(sensors: FakeSensors(HardwareReading(cpuTemperature: 72, fans: [fan], lidClosed: false)))
        rig.helper.with { $0.cooling = .failure(HelperClientError.connection("gone")) }
        let status = await rig.controller.coolingStatus()
        #expect(status == CoolingStatus(cpuTemperature: 72, fans: [fan], isControlling: false,
                                        problem: ClamDownController.noHelperForFans))
    }

    @Test func theHelperAnswerWinsOverLocalSensors() async {
        let rig = Rig(sensors: FakeSensors(HardwareReading(cpuTemperature: 10, fans: [], lidClosed: nil)))
        #expect(await rig.controller.coolingStatus()?.cpuTemperature == 70)
    }

    // MARK: - Telling the user that fan control has stopped

    static let stopped = CoolingStatus(cpuTemperature: 80, fans: [], isControlling: false,
                                       problem: "Fan 1 does not reach the speed it was set to.", control: .stopped)
    static let controlling = CoolingStatus(cpuTemperature: 80, fans: [], isControlling: true, problem: nil,
                                           control: .controlling)
    static let stoppedLine = "ClamDown is not controlling the fans. macOS has them. Fan 1 does not reach the speed it was set to."

    @Test func heartbeatAsksForCoolingWhenFanControlIsOn() async {
        let rig = Rig()
        await rig.controller.toggle()
        let before = rig.helper.coolingCount
        await rig.controller.sendHeartbeat()
        #expect(rig.helper.coolingCount == before + 1)
    }

    @Test func notWhenFanControlIsOff() async {
        var settings = Settings()
        settings.fanControlEnabled = false
        let rig = Rig(settings: settings)
        await rig.controller.toggle()
        await rig.controller.sendHeartbeat()
        #expect(rig.helper.coolingCount == 0)
    }

    @Test func notWhileTheModeIsOff() async {
        let rig = Rig()
        await rig.controller.sendHeartbeat()
        #expect(rig.helper.coolingCount == 0)
    }

    @Test func stoppedHelperPostsOneNotification() async {
        let rig = Rig()
        await rig.controller.toggle()
        rig.helper.with { $0.cooling = .success(Self.stopped) }
        await rig.controller.sendHeartbeat()
        await rig.controller.sendHeartbeat()
        await rig.controller.sendHeartbeat()
        #expect(rig.notifier.posted == [FakeNotifier.Posted(title: "ClamDown", body: Self.stoppedLine)])
        #expect(rig.controller.fanControlLine == Self.stoppedLine)
        // The mode itself is fine: the switch's own line is left alone.
        #expect(rig.controller.state == .on)
        #expect(rig.controller.notice == nil)
    }

    @Test func controlBackClearsTheMenuLine() async {
        let rig = Rig()
        await rig.controller.toggle()
        rig.helper.with { $0.cooling = .success(Self.stopped) }
        await rig.controller.sendHeartbeat()
        rig.helper.with { $0.cooling = .success(Self.controlling) }
        await rig.controller.sendHeartbeat()
        #expect(rig.controller.fanControlLine == nil)
        rig.helper.with { $0.cooling = .success(Self.stopped) }
        await rig.controller.sendHeartbeat()
        #expect(rig.notifier.posted.count == 2)
    }

    @Test func withNotificationsOffTheLineStillShows() async {
        var settings = Settings()
        settings.notificationsEnabled = false
        let rig = Rig(settings: settings)
        await rig.controller.toggle()
        rig.helper.with { $0.cooling = .success(Self.stopped) }
        await rig.controller.sendHeartbeat()
        #expect(rig.controller.fanControlLine == Self.stoppedLine)
        #expect(rig.notifier.posted.isEmpty)
    }

    @Test func turningOffClearsTheLine() async {
        let rig = Rig()
        await rig.controller.toggle()
        rig.helper.with { $0.cooling = .success(Self.stopped) }
        await rig.controller.sendHeartbeat()
        await rig.controller.toggle()
        #expect(rig.controller.fanControlLine == nil)
        // A new session that stops again is a new stop.
        await rig.controller.toggle()
        await rig.controller.sendHeartbeat()
        #expect(rig.notifier.posted.count == 2)
    }

    @Test func switchingFanControlOffClearsTheLine() async {
        let rig = Rig()
        await rig.controller.toggle()
        rig.helper.with { $0.cooling = .success(Self.stopped) }
        await rig.controller.sendHeartbeat()
        var settings = rig.controller.settings
        settings.fanControlEnabled = false
        await rig.controller.updateSettings(settings)
        #expect(rig.controller.fanControlLine == nil)
    }
}
