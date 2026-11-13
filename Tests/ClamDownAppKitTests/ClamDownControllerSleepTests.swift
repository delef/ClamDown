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

    // MARK: Nobody is there

    /// macOS can keep saying "closing the lid sleeps this Mac" in front of an external display. The display wins.
    @Test func noSleepWithAnExternalDisplayConnected() async {
        let rig = await onRig(lid: Self.unattended)
        rig.displays.external = true
        rig.monitor.current = Self.hot
        await rig.controller.handleSystemChange()
        await rig.controller.sleepWatch?.value
        #expect(rig.controller.state == .off)
        #expect(rig.sleeper.sleepCount == 0)
        #expect(rig.controller.notice == "Turned off: Mac is hot (serious). The Mac can sleep now.")
    }

    @Test func noSleepWhileSomeoneKeepsTyping() async {
        let rig = await onRig(lid: Self.unattended)
        rig.idle.time = .seconds(5)
        rig.monitor.current = Self.hot
        await rig.controller.handleSystemChange()
        await rig.controller.sleepWatch?.value
        #expect(rig.sleeper.sleepCount == 0)
        #expect(rig.controller.notice == "Turned off: Mac is hot (serious). The Mac can sleep now.")
        #expect(!rig.pauser.waits.isEmpty && rig.pauser.waits.count <= 6)
        #expect(rig.pauser.waits.allSatisfy { $0 == .seconds(55) })
    }

    @Test func noSleepWhenIdleTimeIsUnknown() async {
        let rig = await onRig(lid: Self.unattended)
        rig.idle.time = nil
        rig.monitor.current = Self.hot
        await rig.controller.handleSystemChange()
        await rig.controller.sleepWatch?.value
        #expect(rig.sleeper.sleepCount == 0)
    }

    /// The lid was closed seconds before the heat trigger: wait out the minute, then sleep.
    @Test func sleepsOnceTheMacHasBeenQuietForAMinute() async {
        let rig = await onRig(lid: Self.unattended)
        rig.idle.time = .seconds(5)
        rig.pauser.whilePaused = { [idle = rig.idle, controller = rig.controller] wait in
            if wait == .seconds(55) { idle.time = .seconds(60) } else { controller.systemWillSleep() }
        }
        rig.monitor.current = Self.hot
        await rig.controller.handleSystemChange()
        #expect(rig.sleeper.sleepCount == 0)
        await rig.controller.sleepWatch?.value
        #expect(rig.pauser.waits == [.seconds(55), .seconds(20)])
        #expect(rig.sleeper.sleepCount == 1)
    }

    // MARK: Sleep that is confirmed

    /// One `pmset sleepnow` can be refused. ClamDown asks again, three times in all, twenty seconds apart.
    @Test func sleepIsAskedAgainWhileTheMacStaysAwake() async {
        let rig = await onRig(lid: Self.unattended)
        rig.monitor.current = Self.hot
        await rig.controller.handleSystemChange()
        #expect(rig.sleeper.sleepCount == 1)
        await rig.controller.sleepWatch?.value
        #expect(rig.sleeper.sleepCount == 3)
        #expect(rig.pauser.waits == [.seconds(20), .seconds(20), .seconds(20)])
    }

    @Test func sleepIsNotAskedAgainOnceTheMacSleeps() async {
        let rig = await onRig(lid: Self.unattended)
        rig.pauser.whilePaused = { [controller = rig.controller] _ in controller.systemWillSleep() }
        rig.monitor.current = Self.hot
        await rig.controller.handleSystemChange()
        await rig.controller.sleepWatch?.value
        #expect(rig.sleeper.sleepCount == 1)
    }

    @Test func sleepIsNotAskedAgainOnceSomeoneOpensTheLid() async {
        let rig = await onRig(lid: Self.unattended)
        rig.pauser.whilePaused = { [lid = rig.lidReader] _ in lid.state = Self.open }
        rig.monitor.current = Self.hot
        await rig.controller.handleSystemChange()
        await rig.controller.sleepWatch?.value
        #expect(rig.sleeper.sleepCount == 1)
    }

    @Test func turningOnStopsTheSleepRequests() async {
        let rig = await onRig(lid: Self.unattended)
        rig.monitor.current = Self.hot
        await rig.controller.handleSystemChange()
        let watch = rig.controller.sleepWatch
        rig.monitor.current = .calm
        await rig.controller.toggle()
        await watch?.value
        #expect(rig.controller.state == .on)
        #expect(rig.sleeper.sleepCount == 1)
    }

    /// The timer and a battery event can both find the mode on while the first switch-off still waits for the helper.
    @Test func overlappingSwitchOffsActOnce() async {
        let rig = await onRig(lid: Self.unattended)
        rig.pauser.whilePaused = { [controller = rig.controller] _ in controller.systemWillSleep() }
        rig.monitor.current = Self.hot
        async let first: Void = rig.controller.handleSystemChange()
        async let second: Void = rig.controller.handleSystemChange()
        _ = await (first, second)
        #expect(rig.notifier.posted.count == 1)
        #expect(rig.sleeper.sleepCount == 1)
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

    /// "The Mac is going to sleep." is stale once the user is back. The menu then says what happened.
    @Test func reportReplacesTheSwitchOffLineInTheMenu() async {
        let rig = await onRig(lid: Self.unattended)
        rig.monitor.current = Self.lowBattery
        await rig.controller.handleSystemChange()
        rig.controller.systemWillSleep()
        rig.lidReader.state = Self.open
        rig.controller.systemDidWake()
        #expect(rig.controller.notice == "ClamDown put the Mac to sleep at \(time(rig)): battery at 5%.")
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
        rig.controller.systemWillSleep()
        rig.controller.systemDidWake()
        #expect(reports.isEmpty)
        rig.lidReader.state = Self.open
        rig.controller.systemDidWake()
        #expect(reports.count == 1)
    }

    /// The Mac was asked to sleep and did not. Saying on return that it slept would be a guess.
    @Test func sleepThatNeverCameIsNotReported() async {
        let rig = await onRig(lid: Self.unattended)
        var reports: [String] = []
        rig.controller.onWakeReport = { reports.append($0) }
        rig.monitor.current = Self.hot
        await rig.controller.handleSystemChange()
        await rig.controller.sleepWatch?.value
        rig.lidReader.state = Self.open
        rig.controller.systemDidWake()
        #expect(reports.isEmpty)
    }

    /// The user saw the switch-off, worked on and closed the lid in the evening. That sleep is their own.
    @Test func switchOffTheUserSatThroughIsNotReportedAfterAMuchLaterSleep() async {
        let rig = await onRig(lid: Self.open)
        var reports: [String] = []
        rig.controller.onWakeReport = { reports.append($0) }
        rig.monitor.current = Self.lowBattery
        await rig.controller.handleSystemChange()
        rig.clock.advance(by: 31 * 60)
        rig.controller.systemWillSleep()
        rig.controller.systemDidWake()
        #expect(reports.isEmpty)
    }

    @Test func sleepWithinHalfAnHourOfTheSwitchOffIsReported() async {
        let rig = await onRig(lid: Self.open)
        var reports: [String] = []
        rig.controller.onWakeReport = { reports.append($0) }
        rig.monitor.current = Self.lowBattery
        await rig.controller.handleSystemChange()
        rig.clock.advance(by: 29 * 60)
        rig.controller.systemWillSleep()
        rig.controller.systemDidWake()
        #expect(reports.count == 1)
    }

    /// Nobody was there to see the switch-off, so they are told however late the Mac fell asleep.
    @Test func switchOffWithTheLidClosedIsReportedEvenAfterALateSleep() async {
        let rig = await onRig(lid: Self.unattended)
        var reports: [String] = []
        rig.controller.onWakeReport = { reports.append($0) }
        rig.pauser.whilePaused = { [clock = rig.clock] _ in clock.advance(by: 3600) }
        rig.monitor.current = Self.hot
        await rig.controller.handleSystemChange()
        await rig.controller.sleepWatch?.value
        rig.controller.systemWillSleep()
        rig.lidReader.state = Self.open
        rig.controller.systemDidWake()
        #expect(reports.count == 1)
    }

    @Test func reportFromAnotherDayNamesTheDay() async {
        let rig = await onRig(lid: Self.unattended)
        var reports: [String] = []
        rig.controller.onWakeReport = { reports.append($0) }
        rig.monitor.current = Self.lowBattery
        await rig.controller.handleSystemChange()
        let switchedOff = rig.clock.now.formatted(date: .abbreviated, time: .shortened)
        rig.controller.systemWillSleep()
        rig.clock.advance(by: 26 * 3600)
        rig.lidReader.state = Self.open
        rig.controller.systemDidWake()
        #expect(reports == ["ClamDown put the Mac to sleep on \(switchedOff): battery at 5%."])
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
