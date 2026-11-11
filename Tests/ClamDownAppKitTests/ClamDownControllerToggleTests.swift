import Testing
@testable import ClamDownAppKit

/// Everything a controller test needs, wired together.
@MainActor
struct Rig {
    let controller: ClamDownController
    let helper = FakeHelper()
    let registrar: FakeRegistrar
    let monitor: FakeMonitor
    let notifier = FakeNotifier()
    let activity = FakeActivity()
    let store: FakeSettingsStore
    let installed: FakeInstalledHelper
    let lid = FakeLidMonitor()
    let locker = FakeScreenLocker()
    let clock = FakeClock()

    init(
        availability: [HelperAvailability] = [.ready],
        snapshot: SystemSnapshot = .calm,
        settings: Settings = Settings(),
        helperFingerprint: String? = nil,
        installedFingerprint: String? = nil,
        heartbeatInterval: Duration = .seconds(3600)
    ) {
        registrar = FakeRegistrar(availability)
        monitor = FakeMonitor(snapshot)
        store = FakeSettingsStore(settings)
        installed = FakeInstalledHelper(installedFingerprint)
        controller = ClamDownController(
            helper: helper,
            registrar: registrar,
            monitor: monitor,
            settingsStore: store,
            notifier: notifier,
            activity: activity,
            installedHelper: installed,
            helperFingerprint: helperFingerprint,
            heartbeatInterval: heartbeatInterval,
            lidMonitor: lid,
            screenLocker: locker,
            now: { [clock] in clock.now }
        )
    }
}

@MainActor @Suite struct ClamDownControllerToggleTests {
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

    @Test func registersWhenMacOSReportsNotFoundBeforeFirstRegistration() async {
        // macOS answers notFound (mapped to .unavailable), not notRegistered, for a helper that was never registered.
        let rig = Rig(availability: [.unavailable("The helper is missing from the app bundle."), .requiresApproval])
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

    @Test func missingHelperStillReportsMissingWhenRegisterFails() async {
        let rig = Rig(availability: [.unavailable("missing")])
        rig.registrar.registerError = HelperClientError.helper("denied")
        await rig.controller.toggle()
        #expect(rig.controller.state == .failed("missing"))
    }

    @Test func helperErrorOnEnableStaysOff() async {
        let rig = Rig()
        rig.helper.with { $0.enableError = HelperClientError.helper("boom") }
        await rig.controller.toggle()
        #expect(rig.controller.state == .failed("boom"))
        #expect(rig.activity.beginCount == 0)
    }

    @Test func failedSettingsSaveKeepsOldSettingsAndReports() async {
        let rig = Rig()
        rig.store.saveError = HelperClientError.connection("disk full")
        var changed = Settings()
        changed.batteryCutoffPercent = 30
        await rig.controller.updateSettings(changed)
        #expect(rig.controller.settings == Settings())
        #expect(rig.store.saved.isEmpty)
        #expect(rig.controller.notice?.contains("Could not save settings") == true)
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
