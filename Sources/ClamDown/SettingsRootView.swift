import SwiftUI
import ClamDownAppKit
import ClamDownUI

/// The settings window: a native split view, the brand and the state of ClamDown above the sidebar items, and the
/// selected page beside them.
struct SettingsRootView: View {
    @ObservedObject var controller: ClamDownController
    let notifications: NotificationAuthorizing
    let openSetup: () -> Void
    @Binding var selection: SettingsPane
    @EnvironmentObject private var updater: Updater

    var body: some View {
        CDSettingsShell(
            items: SettingsPane.allCases.map {
                CDSidebarItem(id: $0, title: $0.title, symbol: $0.symbol, color: $0.color, startsGroup: $0.startsGroup)
            },
            selection: $selection,
            brand: { brand },
            detail: { page(for: $0) })
    }

    /// The app icon, the name and the state, with the switch that turns the mode on or off. The timer button beside
    /// the switch turns it on for a set time while it is off, and sets when it switches off while it is on, as
    /// "Turn On For" and "Turn Off In" in the menu bar menu do.
    private var brand: some View {
        HStack(spacing: 8) {
            HStack(spacing: 10) {
                CDAppIcon(size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text("ClamDown").fontWeight(.semibold)
                    HStack(spacing: 5) {
                        CDStatusDot(controller.state.isOn ? CDColor.success : Color.secondary)
                        Text(statusLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if controller.turnOnStep == nil {
                timerMenu
            }
            Toggle("ClamDown", isOn: Binding(
                get: { controller.state.isOn || controller.turnOnStep != nil },
                set: { on in
                    guard on != controller.state.isOn else { return }
                    Task { await controller.toggle() }
                }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(controller.turnOnStep != nil)
                .help(controller.state.isOn ? "Turns ClamDown off." : "Turns ClamDown on.")
        }
    }

    /// Off: turns the mode on for one of the set times, or until switched off. On: sets when it switches off.
    private var timerMenu: some View {
        let isOn = controller.state.isOn
        return Menu {
            Section(isOn ? "Turn Off In" : "Turn On For") {
                ForEach(AutoOffTimer.sessions, id: \.self) { timer in
                    Button(timer.title) { choose(timer.duration, isOn: isOn) }
                }
            }
            Divider()
            Button("Until Switched Off") { choose(nil, isOn: isOn) }
        } label: {
            // Tinted while a set time runs, so the window shows the session ends by itself, as the menu bar icon does.
            Image(systemName: "timer")
                .foregroundStyle(controller.offAt == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(isOn ? "Sets when ClamDown turns off." : "Turns ClamDown on for a set time.")
        .accessibilityLabel(isOn ? "Turn Off In" : "Turn On For")
    }

    private func choose(_ duration: Duration?, isOn: Bool) {
        if isOn {
            controller.setOffTimer(duration)
        } else {
            Task { await controller.turnOn(for: duration) }
        }
    }

    private var statusLine: String {
        if let step = controller.turnOnStep, !controller.state.isOn { return step.text }
        guard controller.state.isOn else { return String(localized: "Off") }
        if let offAt = controller.offAt {
            return String(localized: "On until \(offAt.formatted(date: .omitted, time: .shortened))")
        }
        return String(localized: "On")
    }

    @ViewBuilder private func page(for pane: SettingsPane) -> some View {
        switch pane {
        case .general: GeneralPage(controller: controller, notifications: notifications)
        case .sleep: SleepPage(controller: controller)
        case .protection: ProtectionPage(controller: controller)
        case .cooling: CoolingPage(controller: controller)
        case .appearance: AppearancePage(controller: controller)
        case .helper: HelperPage(controller: controller, openSetup: openSetup)
        case .about: AboutPage(updater: updater)
        }
    }
}

extension SettingsPane {
    /// The colour of the pane's icon in the sidebar and at the top of its page.
    var color: Color {
        switch self {
        case .general, .about: .gray
        case .sleep: .indigo
        case .protection: .green
        case .cooling: .cyan
        case .appearance: Color(white: 0.15)
        case .helper: .blue
        }
    }
}
