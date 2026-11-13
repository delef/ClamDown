import ClamDownSensors
import Foundation
import Testing
@testable import ClamDownAppKit

@MainActor @Suite struct ClamDownControllerSleepTests {
    private static let unattended = LidState(closed: true, closingCausesSleep: true)
    private static let open = LidState(closed: false, closingCausesSleep: true)
    private static let lowBattery = SystemSnapshot(batteryPercent: 5, isOnBattery: true, thermal: .nominal)
    private static let hot = SystemSnapshot(batteryPercent: 80, isOnBattery: true, thermal: .serious)

    private func onRig(lid: LidState?, settings: Settings = Settings()) async -> Rig {
        let rig = Rig(settings: settings, lidState: lid)
        await rig.controller.toggle()
        return rig
    }

    private func time(_ rig: Rig) -> String {
        rig.clock.now.formatted(date: .omitted, time: .shortened)
    }

    // MARK: Sleep after protection

    @Test func heatSwitchOffSleepsAnUnattendedMac() async {
        let rig = await onRig(lid: Self.unattended)
        rig.monitor.current = Self.hot
        await rig.controller.handleSystemChange()
        #expect(rig.controller.state == .off)
        #expect(rig.sleeper.sleepCount == 1)
        #expect(rig.controller.notice == "Turned off: Mac is hot (serious). The Mac is going to sleep.")
    }

    @Test func batterySwitchOffSleepsAnUnattendedMac() async {
        let rig = await onRig(lid: Self.unattended)
        rig.monitor.current = Self.lowBattery
        await rig.controller.handleSystemChange()
        #expect(rig.sleeper.sleepCount == 1)
        #expect(rig.controller.notice == "Turned off: battery at 5%. The Mac is going to sleep.")
    }

    @Test func noSleepWithTheLidOpen() async {
        let rig = await onRig(lid: Self.open)
        rig.monitor.current = Self.lowBattery
        await rig.controller.handleSystemChange()
        #expect(rig.controller.state == .off)
        #expect(rig.sleeper.sleepCount == 0)
        #expect(rig.controller.notice == "Turned off: battery at 5%. The Mac can sleep now.")
    }

    /// Closed, but macOS keeps it awake by design: someone is working on an external display.
    @Test func noSleepInFrontOfAnExternalDisplay() async {
        let rig = await onRig(lid: LidState(closed: true, closingCausesSleep: false))
        rig.monitor.current = Self.hot
        await rig.controller.handleSystemChange()
        #expect(rig.controller.state == .off)
        #expect(rig.sleeper.sleepCount == 0)
    }

    @Test func noSleepWhenLidIsUnknown() async {
        let rig = await onRig(lid: nil)
        rig.monitor.current = Self.hot
        await rig.controller.handleSystemChange()
        #expect(rig.sleeper.sleepCount == 0)
    }

    @Test func noSleepWhenTheSettingIsOff() async {
        var settings = Settings()
        settings.sleepAfterProtection = false
        let rig = await onRig(lid: Self.unattended, settings: settings)
        rig.monitor.current = Self.hot
        await rig.controller.handleSystemChange()
        #expect(rig.controller.state == .off)
        #expect(rig.sleeper.sleepCount == 0)
    }

    /// The timer is a convenience, not protection: it only allows sleep, as before.
    @Test func timerEndNeverForcesSleep() async {
        let rig = Rig(lidState: Self.unattended)
        await rig.controller.turnOn(for: .seconds(600))
        rig.clock.advance(by: 601)
        await rig.controller.handleSystemChange()
        #expect(rig.controller.state == .off)
        #expect(rig.sleeper.sleepCount == 0)
    }

    /// Sleep is still disabled until the helper's watchdog resets it, so asking for sleep would do nothing useful.
    @Test func noSleepWhenTheHelperDidNotConfirm() async {
        let rig = await onRig(lid: Self.unattended)
        rig.helper.with { $0.disableError = HelperClientError.connection("gone") }
        rig.monitor.current = Self.lowBattery
        await rig.controller.handleSystemChange()
        #expect(rig.controller.state == .off)
        #expect(rig.sleeper.sleepCount == 0)
    }

    // MARK: Told on return

    @Test func reportArrivesOnceAtWakeWithTheLidOpen() async {
        let rig = await onRig(lid: Self.unattended)
        var reports: [String] = []
        rig.controller.onWakeReport = { reports.append($0) }
        rig.monitor.current = Self.lowBattery
        await rig.controller.handleSystemChange()
        rig.controller.systemWillSleep()
        rig.lidReader.state = Self.open
        rig.controller.systemDidWake()
        rig.controller.systemDidWake()
        #expect(reports == ["ClamDown put the Mac to sleep at \(time(rig)): battery at 5%."])
    }

    @Test func allowedSleepIsWordedAsLet() async {
        let rig = Rig(lidState: Self.open)
        var reports: [String] = []
        rig.controller.onWakeReport = { reports.append($0) }
        await rig.controller.turnOn(for: .seconds(600))
        rig.clock.advance(by: 601)
        await rig.controller.handleSystemChange()
        let switchedOffAt = time(rig)
        rig.controller.systemWillSleep()
        rig.controller.systemDidWake()
        #expect(reports == ["ClamDown let the Mac sleep at \(switchedOffAt): timer ended."])
    }

    /// A power event can wake a Mac inside the bag. That is not the user coming back.
    @Test func reportWaitsWhileTheLidIsClosed() async {
        let rig = await onRig(lid: Self.unattended)
        var reports: [String] = []
        rig.controller.onWakeReport = { reports.append($0) }
        rig.monitor.current = Self.hot
        await rig.controller.handleSystemChange()
        rig.controller.systemDidWake()
        #expect(reports.isEmpty)
        rig.lidReader.state = Self.open
        rig.controller.systemDidWake()
        #expect(reports.count == 1)
    }

    /// The user was at the Mac the whole time and saw the notification when it happened.
    @Test func noReportWithoutSleep() async {
        let rig = await onRig(lid: Self.open)
        var reports: [String] = []
        rig.controller.onWakeReport = { reports.append($0) }
        rig.monitor.current = Self.lowBattery
        await rig.controller.handleSystemChange()
        rig.controller.systemDidWake()
        #expect(reports.isEmpty)
    }

    @Test func turnOnDropsThePendingReport() async {
        let rig = await onRig(lid: Self.open)
        var reports: [String] = []
        rig.controller.onWakeReport = { reports.append($0) }
        rig.monitor.current = Self.lowBattery
        await rig.controller.handleSystemChange()
        rig.controller.systemWillSleep()
        rig.monitor.current = .calm
        await rig.controller.toggle()
        rig.controller.systemDidWake()
        #expect(rig.controller.state == .on)
        #expect(reports.isEmpty)
    }

    @Test func lostHelperIsReportedOnReturn() async {
        let rig = await onRig(lid: Self.open)
        var reports: [String] = []
        rig.controller.onWakeReport = { reports.append($0) }
        rig.helper.with { $0.heartbeatResult = .success(false) }
        await rig.controller.sendHeartbeat()
        rig.controller.systemWillSleep()
        rig.controller.systemDidWake()
        #expect(reports == ["ClamDown let the Mac sleep at \(time(rig)): the helper stopped the mode."])
    }
}
