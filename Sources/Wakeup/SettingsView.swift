import SwiftUI
import WakeupAppKit

/// SwiftUI has its own `Settings` scene type, so name ours explicitly.
private typealias AppSettings = WakeupAppKit.Settings

struct SettingsView: View {
    @ObservedObject var controller: WakeupController
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Toggle("Switch on Low Power Mode when running on battery", isOn: binding(\.autoLowPowerOnBattery))

            Stepper(
                "Turn off at \(controller.settings.batteryCutoffPercent)% battery",
                value: binding(\.batteryCutoffPercent),
                in: AppSettings.batteryCutoffRange
            )

            Picker("Turn off when the Mac gets hot", selection: binding(\.thermalCutoff)) {
                ForEach(ThermalCutoff.allCases, id: \.self) { cutoff in
                    Text(label(for: cutoff)).tag(cutoff)
                }
            }

            Toggle("Launch at login", isOn: launchAtLoginBinding)
            if let launchAtLoginError {
                Text(launchAtLoginError).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func label(for cutoff: ThermalCutoff) -> String {
        switch cutoff {
        case .fair: "Fair (earliest)"
        case .serious: "Serious"
        case .critical: "Critical (latest)"
        case .never: "Never"
        }
    }

    /// Edits one setting and sends the whole settings value to the controller.
    private func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { controller.settings[keyPath: keyPath] },
            set: { newValue in
                var updated = controller.settings
                updated[keyPath: keyPath] = newValue
                Task { await controller.updateSettings(updated) }
            }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { controller.settings.launchAtLogin },
            set: { wanted in
                launchAtLoginError = nil
                do {
                    try LaunchAtLogin.apply(wanted)
                } catch {
                    launchAtLoginError = "Could not change launch at login: \(error.localizedDescription)"
                }
                var updated = controller.settings
                updated.launchAtLogin = LaunchAtLogin.isEnabled
                Task { await controller.updateSettings(updated) }
            }
        )
    }
}
