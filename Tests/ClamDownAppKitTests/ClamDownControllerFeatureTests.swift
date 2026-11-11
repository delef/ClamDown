import Foundation
import Testing
@testable import ClamDownAppKit

@MainActor @Suite struct ClamDownControllerFeatureTests {
    // MARK: Timer

    @Test func turnOnForDurationSetsTheDeadline() async {
        let rig = Rig()
        await rig.controller.turnOn(for: .seconds(600))
        #expect(rig.controller.state == .on)
        #expect(rig.controller.offAt == rig.clock.now.addingTimeInterval(600))
    }

    @Test func toggleUsesTheTimerSetting() async {
        var settings = Settings()
        settings.autoOffTimer = .hour1
        let rig = Rig(settings: settings)
        await rig.controller.toggle()
        #expect(rig.controller.offAt == rig.clock.now.addingTimeInterval(3600))
    }

    @Test func noTimerMeansNoDeadline() async {
        let rig = Rig()
        await rig.controller.toggle()
        #expect(rig.controller.offAt == nil)
    }

    @Test func timerSwitchesOffWhenItsTimeComes() async throws {
        let rig = Rig()
        await rig.controller.turnOn(for: .milliseconds(30))
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.controller.state == .off)
        #expect(rig.helper.disableCount == 1)
        #expect(rig.controller.offAt == nil)
        #expect(rig.controller.notice?.contains("timer ended") == true)
    }

    @Test func deadlinePassedWhileAsleepSwitchesOffOnTheNextCheck() async {
        let rig = Rig()
        await rig.controller.turnOn(for: .seconds(600))
        rig.clock.advance(by: 601)
        await rig.controller.handleSystemChange()
        #expect(rig.controller.state == .off)
        #expect(rig.helper.disableCount == 1)
    }

    @Test func switchingOffByHandDropsTheDeadline() async {
        let rig = Rig()
        await rig.controller.turnOn(for: .seconds(600))
        await rig.controller.toggle()
        #expect(rig.controller.offAt == nil)
    }

    @Test func turnOnForDoesNothingWhileAlreadyOn() async {
        let rig = Rig()
        await rig.controller.toggle()
        await rig.controller.turnOn(for: .seconds(600))
        #expect(rig.helper.enableCalls.count == 1)
        #expect(rig.controller.offAt == nil)
    }

    // MARK: Unplugged

    @Test func refusesToTurnOnWhenUnpluggedAndTheSettingIsOn() async {
        var settings = Settings()
        settings.turnOffWhenUnplugged = true
        let rig = Rig(settings: settings)
        await rig.controller.toggle()
        #expect(rig.controller.state == .off)
        #expect(rig.helper.enableCalls.isEmpty)
        #expect(rig.controller.notice == "Not turned on: power adapter unplugged.")
    }

    @Test func switchesOffWhenTheAdapterIsUnplugged() async {
        var settings = Settings()
        settings.turnOffWhenUnplugged = true
        let rig = Rig(snapshot: SystemSnapshot(batteryPercent: 80, isOnBattery: false, thermal: .nominal), settings: settings)
        await rig.controller.toggle()
        rig.monitor.current = .calm
        await rig.controller.handleSystemChange()
        #expect(rig.controller.state == .off)
        #expect(rig.controller.notice?.contains("power adapter unplugged") == true)
    }

    // MARK: Lid

    @Test func watchesTheLidOnlyWhileOn() async {
        let rig = Rig()
        await rig.controller.toggle()
        #expect(rig.lid.startCount == 1)
        await rig.controller.toggle()
        #expect(rig.lid.stopCount == 1)
    }

    @Test func locksTheScreenWhenTheLidClosesWhileOn() async throws {
        let rig = Rig()
        await rig.controller.toggle()
        rig.lid.onClose?()
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.locker.lockCount == 1)
    }

    @Test func doesNotLockWhenTheSettingIsOff() async throws {
        var settings = Settings()
        settings.lockScreenWhenLidClosed = false
        let rig = Rig(settings: settings)
        await rig.controller.toggle()
        rig.lid.onClose?()
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.locker.lockCount == 0)
    }

    // MARK: Notifications and reset

    @Test func quietModeStillShowsTheNoticeButPostsNothing() async {
        var settings = Settings()
        settings.notificationsEnabled = false
        let rig = Rig(snapshot: SystemSnapshot(batteryPercent: 5, isOnBattery: true, thermal: .nominal), settings: settings)
        await rig.controller.toggle()
        #expect(rig.controller.notice == "Not turned on: battery at 5%.")
        #expect(rig.notifier.posted.isEmpty)
    }

    @Test func batteryCutoffCanBeSwitchedOff() async {
        var settings = Settings()
        settings.batteryCutoffEnabled = false
        let rig = Rig(snapshot: SystemSnapshot(batteryPercent: 5, isOnBattery: true, thermal: .nominal), settings: settings)
        await rig.controller.toggle()
        #expect(rig.controller.state == .on)
    }

    @Test func resetRestoresDefaultsButKeepsLaunchAtLogin() async {
        var settings = Settings()
        settings.launchAtLogin = true
        settings.batteryCutoffPercent = 30
        settings.menuBarIcon = .bolt
        let rig = Rig(settings: settings)
        await rig.controller.resetSettings()
        var expected = Settings()
        expected.launchAtLogin = true
        #expect(rig.controller.settings == expected)
    }
}
