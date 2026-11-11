import SwiftUI

/// A titled group of rows on one rounded card, like the sections of AlDente's settings.
struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                content
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
        }
    }
}

/// One setting: icon, title, an optional "?" tooltip and the control on the right.
struct SettingRow<Control: View>: View {
    let icon: String
    let title: String
    var help: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            Text(title)
            if let help {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.tertiary)
                    .help(help)
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// A detail line inside a card, for values that belong to the row above.
struct SettingDetail<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            .padding(.leading, 30)
    }
}

/// Thin divider between two rows of one card.
struct RowDivider: View {
    var body: some View {
        Divider().padding(.leading, 44)
    }
}

/// A switch that reads "Enabled" or "Disabled" next to it, as in AlDente.
struct StatusToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(isOn ? "Enabled" : "Disabled")
                .foregroundStyle(.secondary)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

/// A page of the settings window: a title and a scrolling stack of sections.
struct SettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(title).font(.largeTitle.bold())
                content
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
