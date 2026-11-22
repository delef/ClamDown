import SwiftUI

/// How a line of text or a value is coloured.
public enum CDTone: Sendable {
    case secondary, success, warning, danger

    var style: AnyShapeStyle {
        switch self {
        case .secondary: AnyShapeStyle(.secondary)
        case .success: AnyShapeStyle(CDColor.successText)
        case .warning: AnyShapeStyle(CDColor.warningText)
        case .danger: AnyShapeStyle(CDColor.dangerText)
        }
    }
}

/// The top card of a settings page, as in System Settings: the page's icon, its title and one line saying what the
/// page is for, centred.
public struct CDSettingsPageHeader: View {
    private let title: String
    private let subtitle: String
    private let symbol: String
    private let color: Color

    public init(title: String, subtitle: String, symbol: String, color: Color) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.color = color
    }

    public var body: some View {
        VStack(spacing: 6) {
            CDSettingsIcon(symbol: symbol, color: color, size: 56)
                .padding(.bottom, 4)
            Text(title).font(.title3.bold())
            if !subtitle.isEmpty {
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

/// One page of the settings window: a grouped form, as System Settings draws its panes. The header is the first
/// card and scrolls with the page.
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
        if look == .glass, #available(macOS 26, *) {
            // The form's own background is hidden so the glow shows through; the cards keep their fill.
            form
                .scrollContentBackground(.hidden)
                .background(alignment: .top) { aura }
                .background(Color(nsColor: .windowBackgroundColor))
        } else {
            form
        }
    }

    private var form: some View {
        // No section may be empty: on macOS 27.2 a Form measures the rows of the section after an empty one 36 pt
        // high, which clips them. The header always has content.
        Form {
            Section { header }
            content
        }
        .formStyle(.grouped)
    }

    /// A brand glow from the top left of the page, extended under the glass sidebar, so the sidebar's Liquid Glass
    /// has colour to show instead of flat grey (owner, 2026-11-22: "главное, чтобы был liquid glass", "чуть более
    /// явным"). The system's glass itself has no strength to set; what lies under it is what makes it visible.
    @available(macOS 26, *)
    private var aura: some View {
        let color = colorScheme == .dark ? CDColor.brandMintGlow.opacity(0.16) : CDColor.brandTeal.opacity(0.24)
        return RadialGradient(colors: [color, .clear], center: .topLeading, startRadius: 0, endRadius: 520)
            .frame(height: 460)
            .backgroundExtensionEffect()
            .allowsHitTesting(false)
    }
}

extension CDSettingsPage where Header == CDSettingsPageHeader {
    /// A page whose header is the page's icon with the title and one line of purpose.
    public init(title: String, subtitle: String, symbol: String, color: Color, @ViewBuilder content: () -> Content) {
        self.init(header: { CDSettingsPageHeader(title: title, subtitle: subtitle, symbol: symbol, color: color) },
                  content: content)
    }
}

/// A titled group of rows: one card of the form, with an optional line of small text under it.
public struct CDSection<Content: View>: View {
    private let title: String?
    private let footer: String?
    private let content: Content

    public init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    public var body: some View {
        Section {
            content
        } header: {
            if let title { Text(title) }
        } footer: {
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// The title of a row with an optional explanation under it, which the form draws in the secondary style.
private struct CDRowLabel: View {
    let title: String
    let detail: String?

    var body: some View {
        Text(title)
        if let detail {
            Text(detail)
        }
    }
}

/// One setting: a title, an explanation under it that always shows and wraps, and the control on the right.
/// Laid out by hand rather than with `LabeledContent`: on macOS 27.2 a form measures a `LabeledContent` row whose
/// control is a button one line high, so a second line of explanation runs into the next row.
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
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .accessibilityElement(children: .contain)
    }
}

extension CDRow where Control == EmptyView {
    /// A row that only says something, with no control: a title and an explanation above content of its own.
    public init(_ title: String, detail: String? = nil) {
        self.init(title, detail: detail) { EmptyView() }
    }
}

/// A row with the system switch.
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
        Toggle(isOn: isOn) {
            CDRowLabel(title: title, detail: detail)
        }
        .toggleStyle(.switch)
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
        LabeledContent(title) {
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
