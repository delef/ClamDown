import SwiftUI
import ClamDownAppKit

/// The Launch at Login switch, shared by Settings > General and the setup assistant.
/// macOS owns this state: the user can remove ClamDown under Login Items. So the row shows what the system says.
struct LaunchAtLoginRow: View {
    @ObservedObject var controller: ClamDownController
    var loginItem: LoginItem = .system
    @State private var error: String?

    var body: some View {
        SettingRow(icon: "arrow.right.circle", title: "Launch at Login",
                   help: "Opens ClamDown in the menu bar when you log in.") {
            StatusToggle(isOn: binding)
        }
        .task { await controller.syncLaunchAtLogin(systemValue: loginItem.isEnabled()) }
        // The row can stay on screen for days; coming back from System Settings is when the answer may have changed.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await controller.syncLaunchAtLogin(systemValue: loginItem.isEnabled()) }
        }
        if let error {
            SettingDetail { Text(error).foregroundStyle(.red) }
        }
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { controller.settings.launchAtLogin },
            set: { wanted in
                error = nil
                do {
                    try loginItem.apply(wanted)
                } catch {
                    self.error = "Could not change Launch at Login: \(error.localizedDescription)"
                }
                Task { await controller.syncLaunchAtLogin(systemValue: loginItem.isEnabled()) }
            }
        )
    }
}
