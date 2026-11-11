import AppKit
import ClamDownAppKit
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
    private(set) lazy var settingsWindow = SettingsWindowController(controller: controller)
    private var settingsObserver: AnyCancellable?

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
            screenLocker: LiveScreenLocker()
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
        notifier.requestAuthorization()
        settingsObserver = controller.$settings
            .map(\.showDockIcon)
            .removeDuplicates()
            .sink { NSApp.setActivationPolicy($0 ? .regular : .accessory) }
        Task { await controller.start() }
    }

    /// Clicking the Dock icon, when it is shown, opens the settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show()
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
