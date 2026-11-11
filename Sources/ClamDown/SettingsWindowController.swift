import AppKit
import SwiftUI
import ClamDownAppKit

/// Owns the settings window. AppKit owns it, rather than a SwiftUI scene, so the Dock icon can open it too.
@MainActor
final class SettingsWindowController {
    private let controller: ClamDownController
    private var window: NSWindow?

    init(controller: ClamDownController) {
        self.controller = controller
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsRootView(controller: controller)))
        window.title = "ClamDown"
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("ClamDownSettings")
        return window
    }
}
