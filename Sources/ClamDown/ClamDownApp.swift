import SwiftUI
import ClamDownAppKit

@main
struct ClamDownApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// A debug preview shows made-up states, so it must not offer the real switch next to them.
    private var showsMenuBarItem: Bool {
        #if DEBUG
        !SetupPreview.isRequested
        #else
        true
        #endif
    }

    var body: some Scene {
        MenuBarExtra(isInserted: .constant(showsMenuBarItem)) {
            MenuContent(controller: delegate.controller, updater: delegate.updater,
                        openSettings: { delegate.settingsWindow.show() },
                        openSetup: { delegate.showSetup(.menu) })
        } label: {
            MenuBarIcon(controller: delegate.controller)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuBarIcon: View {
    @ObservedObject var controller: ClamDownController

    var body: some View {
        let presentation = MenuPresentation(state: controller.state, notice: controller.notice,
                                            icon: controller.settings.menuBarIcon,
                                            helperReady: controller.helperAvailability == .ready)
        if presentation.needsAttention {
            Image(nsImage: MenuBarIconImage.attention(symbol: presentation.symbolName))
        } else {
            Image(systemName: presentation.symbolName)
        }
    }
}

private struct MenuContent: View {
    @ObservedObject var controller: ClamDownController
    @ObservedObject var updater: Updater
    let openSettings: () -> Void
    let openSetup: () -> Void

    /// Sessions offered under "Turn On For".
    private static let durations: [AutoOffTimer] = [.minutes30, .hour1, .hours2, .hours4, .hours8]

    var body: some View {
        let presentation = MenuPresentation(state: controller.state, notice: controller.notice,
                                            icon: controller.settings.menuBarIcon)
        Button(presentation.toggleTitle) {
            Task { await controller.toggle() }
        }
        if !controller.state.isOn {
            Menu("Turn On For") {
                ForEach(Self.durations, id: \.self) { timer in
                    Button(timer.title) {
                        Task { await controller.turnOn(for: timer.duration) }
                    }
                }
                Divider()
                Button("Until Switched Off") {
                    Task { await controller.turnOn(for: nil) }
                }
            }
        }
        if let offAt = controller.offAt {
            Text("Turns off at \(offAt.formatted(date: .omitted, time: .shortened))")
        }
        if let line = presentation.statusLine {
            Text(line)
        }
        if controller.helperAvailability != .ready {
            Button("Finish Setup…") {
                openSetup()
            }
        }
        Divider()
        Button("About ClamDown") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(nil)
        }
        if let version = updater.availableVersion {
            Button("Update to \(version)…") { updater.checkForUpdates() }
        } else {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
        Button("Settings…") {
            openSettings()
        }
        .keyboardShortcut(",")
        Button("Quit ClamDown") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
