import SwiftUI

/// How a line of text or a value is coloured.
public enum CDTone: Sendable {
    case secondary, success, warning, danger

    var style: AnyShapeStyle {
        switch self {
        case .secondary: AnyShapeStyle(.secondary)
        case .success: AnyShapeStyle(CDColor.success)
        case .warning: AnyShapeStyle(CDColor.warning)
        case .danger: AnyShapeStyle(CDColor.danger)
        }
    }
}

/// The header of a settings page: a brand tile, the page title and one line saying what the page is for.
public struct CDSettingsPageHeader: View {
    private let title: String
    private let subtitle: String
    private let symbol: String

    public init(title: String, subtitle: String, symbol: String) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
    }

    public var body: some View {
        HStack(spacing: 14) {
            CDBrandTile(symbol: symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.bold())
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One page of the settings window: a header, then grouped sections.
public struct CDSettingsPage<Header: View, Content: View>: View {
    private let header: Header
    private let content: Content
    @Environment(\.cdLook) private var look
    @Environment(\.colorScheme) private var colorScheme

    public init(@ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content) {
        self.header = header()
        self.content = content()
    }

    public var body: some View {
        let form = Form {
            // The header sits where a section header does, so it has no card behind it.
            Section {
                EmptyView()
            } header: {
                header
                    .textCase(nil)
                    .foregroundStyle(.primary)
                    .padding(.bottom, 20)
            }
            .headerProminence(.increased)
            content
        }
        .formStyle(.grouped)
        if look == .glass, #available(macOS 26, *) {
            form
                .scrollContentBackground(.hidden)
                .background(alignment: .top) { aura }
        } else {
            form
        }
    }

    /// A faint brand glow at the top of the page, extended under the glass sidebar.
    @available(macOS 26, *)
    private var aura: some View {
        let color = colorScheme == .dark ? CDColor.brandMintGlow.opacity(0.10) : CDColor.brandTeal.opacity(0.16)
        return RadialGradient(colors: [color, .clear], center: .top, startRadius: 0, endRadius: 300)
            .frame(height: 300)
            .backgroundExtensionEffect()
            .allowsHitTesting(false)
    }
}

extension CDSettingsPage where Header == CDSettingsPageHeader {
    /// A page whose header is the brand tile with the title and one line of purpose.
    public init(title: String, subtitle: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.init(header: { CDSettingsPageHeader(title: title, subtitle: subtitle, symbol: symbol) }, content: content)
    }
}

/// A titled group of rows on one card.
public struct CDSection<Content: View>: View {
    private let title: String?
    private let content: Content

    public init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        if let title {
            // The title is styled here: after the page header's empty section the system styles the first
            // title smaller and lighter than the rest.
            Section { content } header: { Text(title).font(.headline).foregroundStyle(.primary) }
        } else {
            Section { content }
        }
    }
}

/// One setting: a title, an explanation under it that always shows and wraps, and the control on the right.
public struct CDRow<Control: View>: View {
    private let title: String
    private let detail: String?
    private let control: Control

    public init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: CDMetric.rowSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: CDMetric.rowSpacing)
            control
        }
        .accessibilityElement(children: .contain)
    }
}

/// A row with a switch and no "Enabled" or "Disabled" label.
public struct CDSwitchRow: View {
    private let title: String
    private let detail: String?
    private let isOn: Binding<Bool>

    public init(_ title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self.isOn = isOn
    }

    public var body: some View {
        CDRow(title, detail: detail) {
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.cdSwitch)
        }
    }
}

/// A row that shows a value, such as a temperature or a state.
public struct CDValueRow: View {
    private let title: String
    private let value: String
    private let tone: CDTone

    public init(_ title: String, value: String, tone: CDTone = .secondary) {
        self.title = title
        self.value = value
        self.tone = tone
    }

    public var body: some View {
        CDRow(title) {
            Text(value)
                .monospacedDigit()
                .foregroundStyle(tone.style)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// A full-width line of text inside a section, such as a warning.
public struct CDNote: View {
    private let text: String
    private let tone: CDTone

    public init(_ text: String, tone: CDTone = .secondary) {
        self.text = text
        self.tone = tone
    }

    public var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(tone.style)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
