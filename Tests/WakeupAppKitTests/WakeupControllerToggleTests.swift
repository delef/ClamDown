import Testing
@testable import WakeupAppKit

/// Everything a controller test needs, wired together.
@MainActor
struct Rig {
    let controller: WakeupController
    let helper = FakeHelper()
    let registrar: FakeRegistrar
    let monitor: FakeMonitor
    let notifier = FakeNotifier()
    let activity = FakeActivity()
    let store: FakeSettingsStore

    init(
        availability: [HelperAvailability] = [.ready],
        snapshot: SystemSnapshot = .calm,
        settings: Settings = Settings(),
        heartbeatInterval: Duration = .seconds(3600)
    ) {
        registrar = FakeRegistrar(availability)
        monitor = FakeMonitor(snapshot)
        store = FakeSettingsStore(settings)
        controller = WakeupController(
            helper: helper,
            registrar: registrar,
            monitor: monitor,
            settingsStore: store,
            notifier: notifier,
            activity: activity,
            heartbeatInterval: heartbeatInterval
        )
    }
}

@MainActor @Suite struct WakeupControllerToggleTests {
    @Test func toggleOnEnablesHelperWithAutoLowPowerSetting() async {
        let rig = Rig()
        await rig.controller.toggle()
        #expect(rig.helper.enableCalls == [true])
        #expect(rig.controller.state == .on)
        #expect(rig.activity.beginCount == 1)
    }

    @Test func toggleOnPassesAutoLowPowerOffFromSettings() async {
        var settings = Settings()
        settings.autoLowPowerOnBattery = false
        let rig = Rig(settings: settings)
        await rig.controller.toggle()
        #expect(rig.helper.enableCalls == [false])
    }

    @Test func toggleOffDisablesAndEndsActivity() async {
        let rig = Rig()
        await rig.controller.toggle()
        await rig.controller.toggle()
        #expect(rig.helper.disableCount == 1)
        #expect(rig.controller.state == .off)
        #expect(rig.activity.endCount == 1)
    }

    @Test func refusesWhenBatteryAlreadyAtCutoff() async {
        let rig = Rig(snapshot: SystemSnapshot(batteryPercent: 10, isOnBattery: true, thermal: .nominal))
        await rig.controller.toggle()
        #expect(rig.controller.state == .off)
        #expect(rig.helper.enableCalls.isEmpty)
        #expect(rig.notifier.posted.last?.body.contains("battery at 10%") == true)
        #expect(rig.controller.notice?.contains("battery at 10%") == true)
    }

    @Test func refusesWhenThermalAlreadyAtCutoff() async {
        let rig = Rig(snapshot: SystemSnapshot(batteryPercent: 80, isOnBattery: true, thermal: .serious))
        await rig.controller.toggle()
        #expect(rig.controller.state == .off)
        #expect(rig.helper.enableCalls.isEmpty)
        #expect(rig.notifier.posted.last?.body.contains("Mac is hot (serious)") == true)
        #expect(rig.controller.notice?.contains("Mac is hot (serious)") == true)
    }

    @Test func requiresApprovalStaysOffAndOpensSettings() async {
        let rig = Rig(availability: [.requiresApproval])
        await rig.controller.toggle()
        #expect(rig.controller.state == .needsApproval)
        #expect(rig.registrar.openApprovalCount == 1)
        #expect(rig.helper.enableCalls.isEmpty)
    }

    @Test func registersWhenNotRegistered() async {
        let rig = Rig(availability: [.notRegistered, .requiresApproval])
        await rig.controller.toggle()
        #expect(rig.registrar.registerCount == 1)
        #expect(rig.controller.state == .needsApproval)
        #expect(rig.helper.enableCalls.isEmpty)
    }

    @Test func registerFailureShowsMessage() async {
        let rig = Rig(availability: [.notRegistered])
        rig.registrar.registerError = HelperClientError.helper("denied")
        await rig.controller.toggle()
        #expect(rig.controller.state == .failed("denied"))
    }

    @Test func unavailableHelperShowsFailure() async {
        let rig = Rig(availability: [.unavailable("missing")])
        await rig.controller.toggle()
        #expect(rig.controller.state == .failed("missing"))
        #expect(rig.helper.enableCalls.isEmpty)
    }

    @Test func helperErrorOnEnableStaysOff() async {
        let rig = Rig()
        rig.helper.with { $0.enableError = HelperClientError.helper("boom") }
        await rig.controller.toggle()
        #expect(rig.controller.state == .failed("boom"))
        #expect(rig.activity.beginCount == 0)
    }

    @Test func failedDisableKeepsStateOnAndReports() async {
        let rig = Rig()
        await rig.controller.toggle()
        rig.helper.with { $0.disableError = HelperClientError.connection("gone") }
        await rig.controller.toggle()
        #expect(rig.controller.state == .on)
        #expect(rig.controller.notice?.contains("gone") == true)
        #expect(rig.activity.endCount == 0)
    }
}
