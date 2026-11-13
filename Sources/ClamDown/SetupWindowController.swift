import AppKit
import SwiftUI
import ClamDownAppKit

/// Owns the setup assistant's window.
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    private let controller: ClamDownController
    private let store: SetupStoring
    private let notifications: NotificationAuthorizing
    private var window: NSWindow?
    private var model: SetupModel?
    /// Called when the window opens and closes. The app shows its Dock icon while the assistant is open,
    /// so the user can find the window again after a visit to System Settings.
    var onVisibilityChange: (Bool) -> Void = { _ in }

    init(controller: ClamDownController, store: SetupStoring, notifications: NotificationAuthorizing) {
        self.controller = controller
        self.store = store
        self.notifications = notifications
    }

    /// True from `show` until the window closes. Not `window.isVisible`: that is still false while the window
    /// is being opened, still true while it closes, and false for an open window of a hidden app.
    private(set) var isOpen = false

    /// Opens the assistant. An assistant that is already open keeps its place and only comes forward.
    func show(_ presentation: SetupPresentation) {
        guard !isOpen else {
            bringForward()
            return
        }
        show(SetupModel(presentation: presentation, controller: controller, store: store, notifications: notifications),
             controller: controller)
    }

    /// Shows a prepared model. Debug previews use it with a controller and a login item of their own.
    func show(_ model: SetupModel, controller: ClamDownController, loginItem: LoginItem = .system) {
        self.model = model
        let root = SetupView(
            model: model,
            controller: controller,
            close: { [weak self] in self?.window?.close() },
            bringForward: { [weak self] in self?.bringForward() },
            loginItem: loginItem
        )
        let window = window ?? makeWindow()
        window.contentViewController = NSHostingController(rootView: root)
        window.setContentSize(SetupView.size)
        window.center()
        self.window = window
        isOpen = true
        onVisibilityChange(true)
        bringForward()
    }

    func bringForward() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model?.closed()
        model = nil
        // The view polls the helper once a second; dropping it stops that.
        window?.contentViewController = nil
        isOpen = false
        onVisibilityChange(false)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: SetupView.size),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        window.title = "ClamDown Setup"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }
}
