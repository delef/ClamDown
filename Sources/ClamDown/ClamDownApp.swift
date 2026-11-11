import SwiftUI
import ClamDownAppKit

@main
struct ClamDownApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: delegate.controller, openSettings: { delegate.settingsWindow.show() })
        } label: {
            MenuBarIcon(controller: delegate.controller)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuBarIcon: View {
    @ObservedObject var controller: ClamDownController

    var body: some View {
        Image(systemName: MenuPresentation(state: controller.state, notice: controller.notice,
                                           icon: controller.settings.menuBarIcon).symbolName)
    }
}

private struct MenuContent: View {
    @ObservedObject var controller: ClamDownController
    let openSettings: () -> Void

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
        if controller.state == .needsApproval {
            Button("Open Login Items…") {
                controller.openHelperApproval()
            }
        }
        Divider()
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
