import SwiftUI
import WakeupAppKit

@main
struct WakeupApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: delegate.controller)
        } label: {
            MenuBarIcon(controller: delegate.controller)
        }
        .menuBarExtraStyle(.menu)

        Window("Wakeup Settings", id: "settings") {
            SettingsView(controller: delegate.controller)
        }
        .windowResizability(.contentSize)
    }
}

private struct MenuBarIcon: View {
    @ObservedObject var controller: WakeupController

    var body: some View {
        Image(systemName: MenuPresentation(state: controller.state, notice: controller.notice).symbolName)
    }
}

private struct MenuContent: View {
    @ObservedObject var controller: WakeupController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let presentation = MenuPresentation(state: controller.state, notice: controller.notice)
        Button(presentation.toggleTitle) {
            Task { await controller.toggle() }
        }
        if let line = presentation.statusLine {
            Text(line)
        }
        Divider()
        Button("Settings…") {
            // A menu bar app has no Dock icon, so bring the window forward by hand.
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "settings")
        }
        Button("Quit Wakeup") {
            NSApplication.shared.terminate(nil)
        }
    }
}
