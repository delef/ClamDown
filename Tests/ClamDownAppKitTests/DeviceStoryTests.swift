import ClamDownSensors
import Foundation
import Testing
@testable import ClamDownAppKit

/// The checks done by hand on a real Mac on 13 November 2026, replayed start to finish with stand-ins.
/// Each step of a story has its own focused test elsewhere; these keep the steps working together.
/// What they cannot show is macOS itself changing its mind, so the device checks stay worth repeating before a release.
@MainActor @Suite struct DeviceStoryTests {
    private static let open = LidState(closed: false, closingCausesSleep: true)
    private static let closedForSleep = LidState(closed: true, closingCausesSleep: true)
    private static let hot = SystemSnapshot(batteryPercent: 95, isOnBattery: true, thermal: .serious)

    /// Lid closed with the mode on, heat 76 seconds later, sleep, a dark wake in the bag, then the lid opens.
    @Test func closedMacThatGetsHotIsPutToSleepAndTheReturningUserIsTold() async throws {
        let rig = Rig(lidState: Self.open)
        var reports: [String] = []
        rig.controller.onWakeReport = { reports.append($0) }
        rig.idle.time = .seconds(1)

        // Turn On, then the lid closes: the screen locks and the Mac stays awake.
        await rig.controller.toggle()
        rig.lidReader.state = Self.closedForSleep
        rig.lid.onClose?()
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.locker.lockCount == 1)
        #expect(rig.controller.state == .on)
        #expect(rig.helper.disableCount == 0)

        // 76 seconds later the Mac gets hot: off, announced, and asked to sleep once.
        rig.idle.time = .seconds(76)
        rig.monitor.current = Self.hot
        await rig.controller.handleSystemChange()
        let switchedOff = rig.clock.now.formatted(date: .omitted, time: .shortened)
        let watch = rig.controller.sleepWatch
        #expect(rig.controller.state == .off)
        #expect(rig.helper.disableCount == 1)
        #expect(rig.sleeper.sleepCount == 1)
        #expect(rig.notifier.posted.map(\.body) == ["Turned off: Mac is hot (serious). The Mac is going to sleep."])

        // The Mac falls asleep. It stirs in the bag: macOS then says "closing the lid does not sleep this Mac".
        rig.controller.systemWillSleep()
        rig.clock.advance(by: 38)
        rig.lidReader.state = LidState(closed: true, closingCausesSleep: false)
        rig.controller.systemDidWake()
        await watch?.value
        #expect(reports.isEmpty)
        #expect(rig.sleeper.sleepCount == 1)
        rig.controller.systemWillSleep()

        // Three minutes after the switch-off the user opens the lid, and is told once.
        rig.clock.advance(by: 130)
        rig.lidReader.state = LidState(closed: false, closingCausesSleep: false)
        rig.idle.time = .seconds(1)
        rig.controller.systemDidWake()
        rig.controller.systemDidWake()
        let told = "ClamDown put the Mac to sleep at \(switchedOff): Mac is hot (serious)."
        #expect(reports == [told])
        #expect(rig.controller.notice == told)
        #expect(rig.sleeper.sleepCount == 1)
    }

    /// The same Mac at a desk: lid closed in front of a display, someone typing. Heat switches the mode off and nothing more.
    @Test func closedMacAtADeskIsNeverPutToSleep() async {
        let rig = Rig(lidState: Self.closedForSleep)
        var reports: [String] = []
        rig.controller.onWakeReport = { reports.append($0) }
        rig.displays.external = true
        rig.idle.time = .seconds(2)
        await rig.controller.toggle()

        rig.monitor.current = Self.hot
        await rig.controller.handleSystemChange()
        await rig.controller.sleepWatch?.value
        #expect(rig.controller.state == .off)
        #expect(rig.sleeper.sleepCount == 0)
        #expect(rig.pauser.waits.isEmpty)
        #expect(rig.controller.notice == "Turned off: Mac is hot (serious). The Mac can sleep now.")

        // The display goes away and the user stops typing, long after: still no sleep from ClamDown.
        rig.displays.external = false
        rig.idle.time = .seconds(600)
        rig.clock.advance(by: 3600)
        await rig.controller.handleSystemChange()
        #expect(rig.sleeper.sleepCount == 0)
        #expect(reports.isEmpty)
    }

    /// The app was replaced by a newer build while its helper kept running. One press of Turn On must be enough:
    /// macOS needs a pause before it registers the new helper, and the connection made to the old one is dead.
    @Test func turnOnAfterAnUpdateReachesTheNewHelperInOnePress() async throws {
        let newHelper = StubHelper()
        let connections = Connections([StubHelper.connectionToAHelperThatIsGone(), newHelper.connection()])
        let registrar = FakeRegistrar([.ready])
        let installed = FakeInstalledHelper("fingerprint of the old build")
        let controller = ClamDownController(
            helper: XPCHelperClient(connect: { connections.next() }),
            registrar: registrar,
            monitor: FakeMonitor(.calm),
            settingsStore: FakeSettingsStore(),
            notifier: FakeNotifier(),
            activity: FakeActivity(),
            installedHelper: installed,
            helperFingerprint: "fingerprint of the new build",
            heartbeatInterval: .seconds(3600),
            pause: { registrar.pause($0) }
        )

        await controller.toggle()

        #expect(controller.state == .on)
        #expect(registrar.unregisterCount == 1)
        #expect(registrar.pauses == [.seconds(1)])
        #expect(registrar.registerCount == 1)
        #expect(connections.count == 2)
        #expect(newHelper.enableCount == 1)
        #expect(installed.fingerprint == "fingerprint of the new build")
    }
}
