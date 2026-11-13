import AppKit
import Combine
import SwiftUI
import ClamDownAppKit

/// The page the settings window shows. Every change is written to the defaults, so the window opens on the page
/// the user left it on.
@MainActor
final class SettingsSelection: ObservableObject {
    static let defaultsKey = "settingsPane"

    @Published var pane: SettingsPane {
        didSet { defaults.set(pane.rawValue, forKey: Self.defaultsKey) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pane = SettingsPane.restored(from: defaults.string(forKey: Self.defaultsKey))
    }

    /// The page stored last time; anything unknown, from another version, opens General.
    func restore() {
        pane = SettingsPane.restored(from: defaults.string(forKey: Self.defaultsKey))
    }
}

/// Owns the settings window. AppKit owns it, rather than a SwiftUI scene, so the Dock icon can open it too.
@MainActor
final class SettingsWindowController {
    /// The content size of a new window, and the smallest the user can make it.
    static let contentSize = NSSize(width: 780, height: 560)
    static let minimumContentSize = NSSize(width: 720, height: 520)

    private let controller: ClamDownController
    private let updater: Updater
    private let notifications: NotificationAuthorizing
    private let openSetup: () -> Void
    private let selection = SettingsSelection()
    private var window: NSWindow?
    private var titleObserver: AnyCancellable?
    private let sizeGuard = MinimumSizeGuard(contentSize: SettingsWindowController.minimumContentSize)

    init(controller: ClamDownController, updater: Updater, notifications: NotificationAuthorizing,
         openSetup: @escaping () -> Void) {
        self.controller = controller
        self.updater = updater
        self.notifications = notifications
        self.openSetup = openSetup
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Opens the window, or brings it forward. `nil` shows the page the user left it on; a pane shows that page.
    func show(pane: SettingsPane? = nil) {
        if let pane {
            selection.pane = pane
        } else if window == nil {
            selection.restore()
        }
        let window = window ?? makeWindow()
        self.window = window
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let host = SettingsHost(controller: controller, notifications: notifications, openSetup: openSetup,
                                selection: selection)
            .environmentObject(updater)
        let hosting = NSHostingController(rootView: host)
        // The window, not the page that is showing, decides the size; the page only sets the smallest.
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        // The window is titled after the page it shows, as System Settings does.
        window.title = selection.pane.title
        titleObserver = selection.$pane.sink { [weak window] pane in window?.title = pane.title }
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(Self.contentSize)
        window.delegate = sizeGuard
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("ClamDownSettings")
        return window
    }
}

/// Connects the window's page choice to the root view.
private struct SettingsHost: View {
    @ObservedObject var controller: ClamDownController
    let notifications: NotificationAuthorizing
    let openSetup: () -> Void
    @ObservedObject var selection: SettingsSelection

    var body: some View {
        SettingsRootView(controller: controller, notifications: notifications, openSetup: openSetup,
                         selection: $selection.pane)
    }
}

/// Keeps a window from shrinking below a content size. `contentMinSize` is not enough: the hosting controller
/// resets it to zero when its sizing options are empty.
@MainActor
private final class MinimumSizeGuard: NSObject, NSWindowDelegate {
    private let contentSize: NSSize

    init(contentSize: NSSize) {
        self.contentSize = contentSize
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let minimum = sender.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size
        return NSSize(width: max(frameSize.width, minimum.width), height: max(frameSize.height, minimum.height))
    }
}
