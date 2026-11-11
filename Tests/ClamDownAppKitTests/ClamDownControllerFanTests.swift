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
        settings.fanMode = .fullSpeed
        await rig.controller.updateSettings(settings)
        #expect(rig.helper.fanPolicyCalls.map(\.mode) == [.curve, .fullSpeed])
    }

    @Test func otherSettingsDoNotResendThePolicy() async {
        let rig = Rig()
        await rig.controller.toggle()
        var settings = rig.controller.settings
        settings.menuBarIcon = .bolt
        await rig.controller.updateSettings(settings)
        #expect(rig.helper.fanPolicyCalls.count == 1)
    }

    @Test func fanSettingsWhileOffAreOnlyStored() async {
        let rig = Rig()
        var settings = rig.controller.settings
        settings.fanStartTemperature = 50
        await rig.controller.updateSettings(settings)
        #expect(rig.helper.fanPolicyCalls.isEmpty)
        await rig.controller.toggle()
        #expect(rig.helper.fanPolicyCalls.map(\.startTemperature) == [50])
    }

    @Test func coolingStatusIsNilWhenTheHelperIsUnreachable() async {
        let rig = Rig()
        rig.helper.with { $0.cooling = .failure(HelperClientError.connection("gone")) }
        #expect(await rig.controller.coolingStatus() == nil)
    }
}
