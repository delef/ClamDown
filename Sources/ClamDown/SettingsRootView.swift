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
                CDSidebarItem(id: $0, title: $0.title, symbol: $0.symbol, startsGroup: $0.startsGroup)
            },
            selection: $selection,
            brand: { brand },
            detail: { page(for: $0) })
    }

    /// The app icon, the name and the state. Turning the mode on or off and Quit live in the menu bar menu.
    private var brand: some View {
        HStack(spacing: 10) {
            CDAppIcon(size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("ClamDown").fontWeight(.semibold)
                HStack(spacing: 5) {
                    CDStatusDot(controller.state.isOn ? CDColor.success : Color.secondary)
                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusLine: String {
        guard controller.state.isOn else { return "Off" }
        if let offAt = controller.offAt {
            return "On until \(offAt.formatted(date: .omitted, time: .shortened))"
        }
        return "On"
    }

    @ViewBuilder private func page(for pane: SettingsPane) -> some View {
        switch pane {
        case .general: GeneralPage(controller: controller, notifications: notifications)
        case .sleep: SleepPage(controller: controller)
        case .protection: ProtectionPage(controller: controller)
        case .cooling: CoolingPage(controller: controller)
        case .appearance: AppearancePage(controller: controller)
        case .helper: HelperPage(controller: controller, openSetup: openSetup)
        case .about: SettingsPage(title: "About") { EmptyView() }
        }
    }
}
