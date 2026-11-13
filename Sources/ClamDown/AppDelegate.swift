import AppKit
import ClamDownAppKit
import ClamDownSensors
import ClamDownShared
import Combine
import CryptoKit

/// Stands in for the real helper client when the app has no Team ID signature,
/// because then it cannot verify who it is talking to.
private struct UnsignedHelper: HelperControlling {
    func enable(lowPowerOnBattery: Bool) async throws { throw HelperClientError.unsigned }
    func disable() async throws { throw HelperClientError.unsigned }
    func setLowPowerOnBattery(_ on: Bool) async throws { throw HelperClientError.unsigned }
    func heartbeat() async throws -> Bool { throw HelperClientError.unsigned }
    func isEnabled() async throws -> Bool { throw HelperClientError.unsigned }
    func setFanPolicy(_ policy: FanPolicy) async throws { throw HelperClientError.unsigned }
    func coolingStatus() async throws -> CoolingStatus { throw HelperClientError.unsigned }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller: ClamDownController
    private let notifier = UserNotificationNotifier()
    /// True in a debug build started for one of its debug tools, such as drawing the setup assistant in made-up
    /// states: nothing real runs next to them, neither the menu bar switch nor the updater.
    static var isDebugPreview: Bool {
        #if DEBUG
        SetupPreview.isRequested || HelperProbe.isRequested
        #else
        false
        #endif
    }

    let updater = Updater(starts: !AppDelegate.isDebugPreview)
    private let setupStore = UserDefaultsSetupStore()
    private(set) lazy var setupWindow = SetupWindowController(controller: controller, store: setupStore, notifications: notifier)
    private(set) lazy var settingsWindow = SettingsWindowController(
        controller: controller, updater: updater, notifications: notifier,
        openSetup: { [weak self] in self?.showSetup(.settings) })
    private var observers: Set<AnyCancellable> = []
    private var helperTimer: Timer?
    private var showDockIcon = false

    override init() {
        let appBundleID = Bundle.main.bundleIdentifier ?? "unknown"
        let label = Identifiers.helperLabel(appBundleID: appBundleID)
        let helper: HelperControlling
        if let teamID = SigningIdentity.currentTeamID(),
           let requirement = CodeRequirement.make(identifier: label, teamID: teamID) {
            helper = XPCHelperClient(machServiceName: label, requirement: requirement)
        } else {
            helper = UnsignedHelper()
        }
        controller = ClamDownController(
            helper: helper,
            registrar: SMAppServiceRegistrar(plistName: label + ".plist"),
            monitor: LiveSystemMonitor(),
            settingsStore: UserDefaultsSettingsStore(),
            notifier: notifier,
            activity: AppNapActivity(),
            installedHelper: UserDefaultsInstalledHelperStore(),
            helperFingerprint: Self.helperFingerprint(),
            lidMonitor: LiveLidMonitor(),
            screenLocker: LiveScreenLocker(),
            sensors: SMCFanHardware(),
            lid: SystemLid(),
            idle: SystemIdle(),
            displays: SystemDisplays(),
            sleeper: LiveSystemSleeper()
        )
        super.init()
    }

    /// Identifies the helper binary in this build. Unlike the version number, it changes with every build,
    /// so an updated app always reinstalls its helper.
    private static func helperFingerprint() -> String? {
        guard let url = Bundle.main.url(forAuxiliaryExecutable: "ClamDownHelper"),
              let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.$settings
            .map(\.showDockIcon)
            .removeDuplicates()
            .sink { [weak self] wanted in
                self?.showDockIcon = wanted
                self?.applyActivationPolicy()
            }
            .store(in: &observers)
        setupWindow.onVisibilityChange = { [weak self] _ in self?.applyActivationPolicy() }
        #if DEBUG
        if HelperProbe.isRequested {
            Task {
                let label = Identifiers.helperLabel(appBundleID: Bundle.main.bundleIdentifier ?? "unknown")
                await HelperProbe.run(plistName: label + ".plist")
                exit(0)
            }
            return
        }
        if SetupPreview.run(setupWindow: setupWindow) { return }
        #endif

        // The published values change after this notice, so read them on the next turn of the run loop.
        controller.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.applyDockBadge()
                self?.scheduleHelperRefresh()
            }
            .store(in: &observers)
        controller.onHelperNeedsApproval = { [weak self] in self?.showSetup(.turnOnNeedsApproval) }
        controller.onWakeReport = { [weak self] text in self?.deliverWakeReport(text) }
        observeSleepAndWake()
        controller.refreshHelperAvailability()
        scheduleHelperRefresh()
        Task { await controller.start() }

        if SetupFlow.completesSilently(completed: setupStore.completed, helper: controller.helperAvailability) {
            setupStore.completed = true
        }
        showSetup(.launch)
        applyDockBadge()
    }

    /// macOS sends no notice when the helper's approval changes in System Settings, so the app asks on a timer:
    /// every few seconds while something waits on the user, rarely otherwise.
    private func scheduleHelperRefresh() {
        let interval = HelperRefreshPace.interval(needsAttention: controller.needsAttention)
        guard helperTimer?.timeInterval != interval else { return }
        helperTimer?.invalidate()
        helperTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.controller.refreshHelperAvailability() }
        }
    }

    /// Opens the setup assistant for an entry point, when the rules say it has something to show.
    func showSetup(_ entry: SetupEntry) {
        guard let presentation = SetupFlow.presentation(for: entry, completed: setupStore.completed,
                                                        helper: controller.helperAvailability) else { return }
        setupWindow.show(presentation)
    }

    /// The controller needs to know when the Mac sleeps and when someone is back at it.
    /// The screens waking covers a lid that opens after the Mac itself was already awake.
    private func observeSleepAndWake() {
        let center = NSWorkspace.shared.notificationCenter
        center.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in self?.controller.systemWillSleep() }
            .store(in: &observers)
        center.publisher(for: NSWorkspace.didWakeNotification)
            .merge(with: center.publisher(for: NSWorkspace.screensDidWakeNotification))
            .sink { [weak self] _ in self?.controller.systemDidWake() }
            .store(in: &observers)
    }

    /// Tells the returning user why ClamDown let the Mac sleep, in a window that stays until they close it.
    /// A notification banner is gone in seconds, and it can pass while the screen is still waking or locked.
    private func deliverWakeReport(_ text: String) {
        // From the run loop, not from a task: a window that waits for a click inside a main-actor task
        // would hold up everything else the app does on the main actor until it is closed.
        RunLoop.main.perform {
            MainActor.assumeIsolated {
                let alert = NSAlert()
                alert.messageText = "ClamDown switched off while you were away"
                alert.informativeText = text
                alert.addButton(withTitle: "OK")
                alert.window.level = .floating
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    /// The Dock icon follows the setting, and is always there while the setup assistant is open.
    private func applyActivationPolicy() {
        let wanted: NSApplication.ActivationPolicy = showDockIcon || setupWindow.isOpen ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
        // Losing the Dock icon can drop an open settings window behind other apps; keep it where the user left it.
        if wanted == .accessory, settingsWindow.isVisible {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func applyDockBadge() {
        NSApp.dockTile.badgeLabel = controller.needsAttention ? "!" : nil
    }

    /// Clicking the Dock icon, when it is shown, opens the settings, or brings an open setup assistant forward.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if setupWindow.isOpen {
            setupWindow.bringForward()
        } else {
            settingsWindow.show()
        }
        return true
    }

    /// Switches the helper off before quitting, but never makes the user wait more than 5 seconds.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let controller = controller
        Task {
            await awaitingAtMost(.seconds(5)) { await controller.shutdown() }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
