import AppKit
import WakeupAppKit
import WakeupShared

/// Stands in for the real helper client when the app has no Team ID signature,
/// because then it cannot verify who it is talking to.
private struct UnsignedHelper: HelperControlling {
    func enable(lowPowerOnBattery: Bool) async throws { throw HelperClientError.unsigned }
    func disable() async throws { throw HelperClientError.unsigned }
    func setLowPowerOnBattery(_ on: Bool) async throws { throw HelperClientError.unsigned }
    func heartbeat() async throws -> Bool { throw HelperClientError.unsigned }
    func isEnabled() async throws -> Bool { throw HelperClientError.unsigned }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller: WakeupController
    private let notifier = UserNotificationNotifier()

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
        controller = WakeupController(
            helper: helper,
            registrar: SMAppServiceRegistrar(plistName: label + ".plist"),
            monitor: LiveSystemMonitor(),
            settingsStore: UserDefaultsSettingsStore(),
            notifier: notifier,
            activity: AppNapActivity()
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        notifier.requestAuthorization()
        Task { await controller.start() }
    }

    /// Switches the helper off before quitting, but never makes the user wait more than 5 seconds.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let controller = controller
        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await controller.shutdown() }
                group.addTask { try? await Task.sleep(for: .seconds(5)) }
                await group.next()
                group.cancelAll()
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
