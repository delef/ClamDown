import SwiftUI
import ClamDownAppKit

@main
struct ClamDownApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra(isInserted: .constant(!AppDelegate.isDebugPreview)) {
            MenuContent(controller: delegate.controller, updater: delegate.updater,
                        openSettings: { delegate.settingsWindow.show(pane: $0) },
                        openSetup: { delegate.showSetup(.menu) })
        } label: {
            MenuBarIcon(controller: delegate.controller)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuBarIcon: View {
    @ObservedObject var controller: ClamDownController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// While a Turn On runs, the icon swaps between its off and on look, so a closed menu still shows that
    /// something is under way. A loop, not an animation: the menu bar draws the label as a still image.
    @State private var blinkOn = false

    var body: some View {
        let icon = controller.settings.menuBarIcon
        let presentation = MenuPresentation(state: controller.state, notice: controller.notice, icon: icon,
                                            helperReady: controller.helperAvailability == .ready,
                                            turnOnStep: controller.turnOnStep, offAt: controller.offAt)
        let symbol = presentation.isTurningOn && blinkOn && !reduceMotion ? icon.onSymbol : presentation.symbolName
        Group {
            if let badge = presentation.badge {
                Image(nsImage: MenuBarIconImage.badged(symbol: symbol, badge: badge))
            } else {
                Image(nsImage: MenuBarIconImage.base(symbol: symbol) ?? NSImage())
            }
        }
        .accessibilityLabel(presentation.accessibilityLabel)
        .task(id: presentation.isTurningOn) {
            blinkOn = false
            // Runs only while a Turn On does, so an idle app is not woken.
            while presentation.isTurningOn, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(600))
                blinkOn.toggle()
            }
        }
    }
}

private struct MenuContent: View {
    @ObservedObject var controller: ClamDownController
    @ObservedObject var updater: Updater
    /// Opens Settings on a page; `nil` shows the page the user left it on.
    let openSettings: (SettingsPane?) -> Void
    let openSetup: () -> Void

    var body: some View {
        let presentation = MenuPresentation(state: controller.state, notice: controller.notice,
                                            icon: controller.settings.menuBarIcon,
                                            helperReady: controller.helperAvailability == .ready,
                                            coolingLine: controller.fanControlLine,
                                            turnOnStep: controller.turnOnStep)
        Button(presentation.toggleTitle) {
            Task { await controller.toggle() }
        }
        .disabled(!presentation.toggleEnabled)
        if !controller.state.isOn, !presentation.isTurningOn {
            Menu("Turn On For") {
                ForEach(AutoOffTimer.sessions, id: \.self) { timer in
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
        if controller.state.isOn {
            Menu("Turn Off In") {
                ForEach(AutoOffTimer.sessions, id: \.self) { timer in
                    Button(timer.title) { controller.setOffTimer(timer.duration) }
                }
                Divider()
                Button("Until Switched Off") { controller.setOffTimer(nil) }
            }
        }
        if let offAt = controller.offAt {
            Text("Turns off at \(offAt.formatted(date: .omitted, time: .shortened))")
        }
        if let line = presentation.statusLine {
            Text(line)
        }
        if let line = presentation.coolingLine {
            Text(line)
        }
        switch presentation.recovery {
        case .finishSetup:
            Button("Finish Setup…") {
                openSetup()
            }
        case .reinstallHelper:
            Button("Reinstall Helper") {
                Task { await controller.reinstallHelper() }
            }
        case nil:
            EmptyView()
        }
        Divider()
        Button("About ClamDown") {
            openSettings(.about)
        }
        if let version = updater.availableVersion {
            Button("Update to \(version)…") { updater.checkForUpdates() }
        } else {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
        Button("Settings…") {
            openSettings(nil)
        }
        .keyboardShortcut(",")
        Button("Quit ClamDown") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
