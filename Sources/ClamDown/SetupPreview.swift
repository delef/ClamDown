#if DEBUG
import AppKit
import SwiftUI
import ClamDownAppKit
import ClamDownSensors
import ClamDownShared

/// Debug builds only: shows or draws the setup assistant in states a Mac that is already set up cannot reach,
/// such as "notifications never asked" or a registration error. Nothing here touches the real helper, settings,
/// notification permission or login item: every one is a stand-in, and the menu bar item is not shown.
///
///     ClamDown -setupSnapshot <directory>   draws every screen to PNG files, light and dark, then quits
///     ClamDown -setupPreview <scenario>     opens the assistant in that state
@MainActor
enum SetupPreview {
    enum Scenario: String, CaseIterable {
        case welcome, helperNotSetUp, helperWaiting, helperError, helperAllowed
        case notificationsNotAsked, notificationsAllowed, notificationsDenied
        case startup, done, helperOnlyWaiting, helperOnlyAllowed

        private var mode: SetupMode {
            switch self {
            case .helperOnlyWaiting, .helperOnlyAllowed: .helperOnly
            default: .full
            }
        }

        private var step: SetupStep {
            switch self {
            case .welcome: .welcome
            case .helperNotSetUp, .helperWaiting, .helperError, .helperAllowed, .helperOnlyWaiting, .helperOnlyAllowed: .helper
            case .notificationsNotAsked, .notificationsAllowed, .notificationsDenied: .notifications
            case .startup: .startup
            case .done: .done
            }
        }

        private var helper: HelperAvailability {
            switch self {
            case .helperNotSetUp, .helperError: .notRegistered
            case .helperWaiting, .helperOnlyWaiting: .requiresApproval
            default: .ready
            }
        }

        private var permission: NotificationPermission {
            switch self {
            case .notificationsNotAsked: .notAsked
            case .notificationsDenied: .denied
            default: .allowed
            }
        }

        @MainActor func make() async -> (SetupModel, ClamDownController) {
            let registerError = self == .helperError ? NSError(domain: "SMAppServiceErrorDomain", code: 1) : nil
            let controller = ClamDownController(
                helper: PreviewHelper(),
                registrar: PreviewRegistrar(state: helper, registerError: registerError),
                monitor: LiveSystemMonitor(),
                settingsStore: PreviewSettingsStore(),
                notifier: PreviewNotifier(),
                activity: AppNapActivity(),
                installedHelper: PreviewInstalledHelper(),
                sensors: SMCFanHardware()
            )
            let model = SetupModel(presentation: SetupPresentation(mode: mode, step: step), controller: controller,
                                   store: PreviewSetupStore(), notifications: PreviewNotifications(state: permission))
            if self == .helperError { await model.allowHelper() }
            await model.refreshNotifications()
            return (model, controller)
        }
    }

    /// True when this launch is a preview or a snapshot run.
    static var isRequested: Bool {
        let arguments = UserDefaults.standard
        return arguments.string(forKey: "setupSnapshot") != nil || arguments.string(forKey: "setupPreview") != nil
    }

    /// A login item that only remembers what the switch was set to.
    private static func memoryLoginItem() -> LoginItem {
        var enabled = false
        return LoginItem(isEnabled: { enabled }, apply: { enabled = $0 })
    }

    /// Returns true when a debug argument took over the launch.
    static func run(setupWindow: SetupWindowController) -> Bool {
        let arguments = UserDefaults.standard
        if let directory = arguments.string(forKey: "setupSnapshot") {
            Task {
                await snapshot(into: URL(fileURLWithPath: directory))
                exit(0)
            }
            return true
        }
        if let name = arguments.string(forKey: "setupPreview") {
            guard let scenario = Scenario(rawValue: name) else {
                print("unknown scenario '\(name)'. Known: \(Scenario.allCases.map(\.rawValue).joined(separator: ", "))")
                exit(2)
            }
            // With no menu bar item the window is the whole app: closing it ends the preview.
            let whenVisibilityChanges = setupWindow.onVisibilityChange
            setupWindow.onVisibilityChange = { visible in
                whenVisibilityChanges(visible)
                if !visible { NSApp.terminate(nil) }
            }
            Task {
                let (model, controller) = await scenario.make()
                setupWindow.show(model, controller: controller, loginItem: memoryLoginItem())
            }
            return true
        }
        return false
    }

    private static func snapshot(into directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
        for (suffix, appearance) in appearances {
            for scenario in Scenario.allCases {
                let (model, controller) = await scenario.make()
                let view = SetupView(model: model, controller: controller, close: {}, bringForward: {},
                                     loginItem: memoryLoginItem())
                await draw(view, size: SetupView.size, appearance: appearance,
                           to: directory.appendingPathComponent("\(scenario.rawValue)-\(suffix).png"))
            }
            await draw(MenuBarIconSheet(), size: CGSize(width: 520, height: 150), appearance: appearance,
                       to: directory.appendingPathComponent("menu-bar-icons-\(suffix).png"))
        }
        print("wrote the setup screens to \(directory.path)")
    }

    private static func draw<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name, to url: URL) async {
        // Far off screen: the view must sit in a window for its tasks to run, but nobody should see it.
        let window = ActiveLookingWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
                                         styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(500))
        hosting.layoutSubtreeIfNeeded()
        if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
        window.contentView = nil
        window.orderOut(nil)
    }
}

/// Draws its controls as the frontmost window would, so buttons show their accent color in the pictures.
private final class ActiveLookingWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

/// Every menu bar icon style, plain and with the attention mark, enlarged for checking the drawing.
private struct MenuBarIconSheet: View {
    var body: some View {
        VStack(spacing: 6) {
            row(\.offSymbol)
            row(\.onSymbol)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func row(_ symbol: KeyPath<MenuBarIconStyle, String>) -> some View {
        HStack(spacing: 0) {
            ForEach(MenuBarIconStyle.allCases, id: \.self) { style in
                Image(systemName: style[keyPath: symbol]).scaleEffect(2.5).frame(width: 62, height: 66)
                Image(nsImage: MenuBarIconImage.attention(symbol: style[keyPath: symbol])).scaleEffect(2.5).frame(width: 62, height: 66)
            }
        }
    }
}

private struct PreviewHelper: HelperControlling {
    private static let unavailable = HelperClientError.connection("Preview: there is no helper.")
    func enable(lowPowerOnBattery: Bool) async throws { throw Self.unavailable }
    func disable() async throws { throw Self.unavailable }
    func setLowPowerOnBattery(_ on: Bool) async throws { throw Self.unavailable }
    func heartbeat() async throws -> Bool { throw Self.unavailable }
    func isEnabled() async throws -> Bool { throw Self.unavailable }
    func setFanPolicy(_ policy: FanPolicy) async throws { throw Self.unavailable }
    func coolingStatus() async throws -> CoolingStatus { throw Self.unavailable }
}

private struct PreviewRegistrar: HelperRegistering {
    let state: HelperAvailability
    let registerError: NSError?

    func availability() -> HelperAvailability { state }
    func register() throws { if let registerError { throw registerError } }
    func unregister() async throws {}
    func openApprovalSettings() {}
}

private struct PreviewNotifications: NotificationAuthorizing {
    let state: NotificationPermission

    func permission() async -> NotificationPermission { state }
    func requestPermission() async -> NotificationPermission { state }
}

private struct PreviewNotifier: Notifying {
    func post(title: String, body: String) {}
}

private final class PreviewSettingsStore: SettingsStoring {
    private var settings = ClamDownAppKit.Settings()
    func load() -> ClamDownAppKit.Settings { settings }
    func save(_ settings: ClamDownAppKit.Settings) throws { self.settings = settings }
}

private final class PreviewSetupStore: SetupStoring {
    var completed = false
}

private final class PreviewInstalledHelper: InstalledHelperStoring {
    var fingerprint: String?
}
#endif
