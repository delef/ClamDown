import SwiftUI
import ClamDownAppKit

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case sleep = "Sleep"
    case protection = "Protection"
    case cooling = "Cooling"
    case appearance = "Appearance"
    case helper = "Helper"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .sleep: "moon.zzz"
        case .protection: "shield.lefthalf.filled"
        case .cooling: "fan"
        case .appearance: "paintbrush"
        case .helper: "wrench.and.screwdriver"
        }
    }
}

/// The settings window: a sidebar of pages on the left, the selected page on the right.
struct SettingsRootView: View {
    @ObservedObject var controller: ClamDownController
    @State private var tab: SettingsTab = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 720, height: 520)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SettingsTab.allCases) { item in
                Button { tab = item } label: {
                    Label(item.rawValue, systemImage: item.icon)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(tab == item ? Color.accentColor.opacity(0.18) : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            footer
        }
        .padding(12)
        .padding(.top, 20)
        .frame(width: 190)
        .background(.regularMaterial)
    }

    /// Version and current state. Turning the mode on or off and quitting live in the menu bar menu.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("ClamDown \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                .font(.callout.weight(.medium))
            Text(statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var statusLine: String {
        guard controller.state.isOn else { return "Off" }
        if let offAt = controller.offAt {
            return "On until \(offAt.formatted(date: .omitted, time: .shortened))"
        }
        return "On"
    }

    @ViewBuilder private var page: some View {
        switch tab {
        case .general: GeneralPage(controller: controller)
        case .sleep: SleepPage(controller: controller)
        case .protection: ProtectionPage(controller: controller)
        case .cooling: CoolingPage(controller: controller)
        case .appearance: AppearancePage(controller: controller)
        case .helper: HelperPage(controller: controller)
        }
    }
}
