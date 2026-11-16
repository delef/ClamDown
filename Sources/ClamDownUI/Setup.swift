import SwiftUI

/// The setup assistant's background: a soft gradient with a glow behind the step icon. The content layer, never glass.
public struct CDSetupBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public var body: some View {
        let dark = colorScheme == .dark
        ZStack {
            // 170 degrees: nearly straight down, leaning a little to the right.
            LinearGradient(
                colors: dark
                    ? [Color(red: 0x0B / 255, green: 0x16 / 255, blue: 0x30 / 255),
                       Color(red: 0x0C / 255, green: 0x30 / 255, blue: 0x36 / 255)]
                    : [Color(red: 0xEE / 255, green: 0xF4 / 255, blue: 0xFB / 255),
                       Color(red: 0xDD / 255, green: 0xEE / 255, blue: 0xF0 / 255)],
                startPoint: UnitPoint(x: 0.41, y: 0), endPoint: UnitPoint(x: 0.59, y: 1))
            RadialGradient(
                colors: [(dark ? CDColor.brandMintGlow : CDColor.brandTeal).opacity(0.16), .clear],
                center: UnitPoint(x: 0.5, y: 0.22), startRadius: 0, endRadius: 340)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// The picture at the top of a setup step.
public enum CDStepIcon {
    /// The app icon, for the first step.
    case app
    /// An SF Symbol on a disc in the brand gradient.
    case symbol(String)
    /// A checkmark on a green disc, for the last step.
    case success
}

public struct CDStepIconView: View {
    private let icon: CDStepIcon

    public init(_ icon: CDStepIcon) {
        self.icon = icon
    }

    public var body: some View {
        switch icon {
        case .app:
            CDAppIcon(size: 92)
        case .symbol(let name):
            disc(name, fill: CDColor.brandGradient, shadow: CDColor.brandNavy)
        case .success:
            disc("checkmark",
                 fill: LinearGradient(colors: [Color(red: 0x0F / 255, green: 0x7A / 255, blue: 0x5C / 255),
                                               Color(red: 0x19 / 255, green: 0xA3 / 255, blue: 0x7A / 255)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing),
                 shadow: Color(red: 0x0F / 255, green: 0x7A / 255, blue: 0x5C / 255))
        }
    }

    private func disc(_ symbol: String, fill: LinearGradient, shadow: Color) -> some View {
        Circle()
            .fill(fill)
            .overlay {
                Circle().strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.3), .clear], startPoint: .top, endPoint: .center),
                    lineWidth: 1)
            }
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(width: 72, height: 72)
            .shadow(color: shadow.opacity(0.3), radius: 13, y: 8)
            .accessibilityHidden(true)
    }
}

/// The top of a setup step: the picture, the title and a line of explanation.
public struct CDStepHeader: View {
    private let icon: CDStepIcon
    private let title: String
    private let text: String

    public init(icon: CDStepIcon, title: String, text: String) {
        self.icon = icon
        self.title = title
        self.text = text
    }

    public var body: some View {
        VStack(spacing: 0) {
            CDStepIconView(icon)
            Text(title)
                .font(.system(size: 28, weight: .bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 18)
                .accessibilityAddTraits(.isHeader)
            Text(text)
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
        .frame(maxWidth: 450)
    }
}

/// One setup step: the header, then the step's own content (cards, notes) 22 pt below it, at most 470 pt wide.
/// The step sits in a vertical scroll view that only scrolls when the step is taller than the space it is given
/// (a long error, larger text), so the caller's footer is never overlapped. `topInset` keeps the icon clear of a
/// transparent title bar and scrolls away with the step.
public struct CDStepScreen<Content: View>: View {
    private let icon: CDStepIcon
    private let title: String
    private let text: String
    private let topInset: CGFloat
    private let content: Content
    @State private var stepHeight: CGFloat = 0

    /// `topInset` keeps the content clear of the window's title bar; below it the content sits in the middle.
    public init(icon: CDStepIcon, title: String, text: String, topInset: CGFloat = 28,
                @ViewBuilder content: () -> Content) {
        self.icon = icon
        self.title = title
        self.text = text
        self.topInset = topInset
        self.content = content()
    }

    public var body: some View {
        GeometryReader { proxy in
            let fits = stepHeight + topInset <= proxy.size.height + 0.5
            ScrollView(.vertical, showsIndicators: !fits) {
                VStack(spacing: 0) {
                    CDStepHeader(icon: icon, title: title, text: text)
                    content
                        .frame(maxWidth: 470)
                        .padding(.top, 22)
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
                .background {
                    GeometryReader { inner in
                        Color.clear.preference(key: CDStepHeightKey.self, value: inner.size.height)
                    }
                }
                // A step that fits sits in the middle of the space under the title bar; a taller one scrolls.
                .frame(minHeight: fits ? max(proxy.size.height - topInset, 0) : nil)
                .padding(.top, topInset)
            }
            .scrollDisabled(fits)
            .onPreferenceChange(CDStepHeightKey.self) { stepHeight = $0 }
        }
    }
}

private struct CDStepHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

extension CDStepScreen where Content == EmptyView {
    public init(icon: CDStepIcon, title: String, text: String, topInset: CGFloat = 28) {
        self.init(icon: icon, title: title, text: text, topInset: topInset) { EmptyView() }
    }
}

/// A picture of the menu bar for the last setup step: a capsule with the app's icon ringed in the accent colour,
/// and the clock after it. The icon is the caller's view, so it can be the drawn Lid or a symbol.
public struct CDMenuBarStrip<Icon: View>: View {
    private let clock: String
    private let icon: Icon
    @Environment(\.cdLook) private var look
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    public init(clock: String, @ViewBuilder icon: () -> Icon) {
        self.clock = clock
        self.icon = icon()
    }

    public var body: some View {
        let strip = CDGlassCapsule {
            HStack(spacing: 18) {
                Spacer(minLength: 0)
                icon
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .opacity(pulsing ? 0.45 : 1)
                    }
                Text(clock)
                    .font(.system(size: 12.5))
                    .monospacedDigit()
            }
            .frame(maxWidth: 420)
        }
        Group {
            if look == .glass {
                strip
            } else {
                // Without glass the strip is a plain capsule of material, as the menu bar is before macOS 26.
                strip.background(.regularMaterial, in: Capsule())
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { pulsing = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "The ClamDown icon in the menu bar"))
    }
}

/// A card for the facts of a setup step, never glass. It has the fill and edge of a settings card and a soft
/// shadow: a material would take on the gradient behind it and the card would fade into it.
public struct CDStatusCard<Content: View>: View {
    private let content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: CDMetric.setupCardRadius, style: .continuous)
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity)
            .background {
                shape.fill(CDColor.cardBackground)
                    .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
            }
            .overlay { shape.strokeBorder(CDColor.cardBorder(contrast)) }
    }
}

/// One line of a status card: a symbol that changes with the state, a title, an optional detail, an action.
/// `busy` shows a spinner in place of the symbol while work is under way.
public struct CDStatusLine<Action: View>: View {
    private let symbol: String
    private let busy: Bool
    private let tint: Color
    private let title: String
    private let detail: String?
    private let detailTone: CDTone
    private let action: Action

    public init(symbol: String, busy: Bool = false, tint: Color, title: String, detail: String? = nil,
                detailTone: CDTone = .secondary, @ViewBuilder action: () -> Action) {
        self.symbol = symbol
        self.busy = busy
        self.tint = tint
        self.title = title
        self.detail = detail
        self.detailTone = detailTone
        self.action = action()
    }

    public var body: some View {
        HStack(spacing: 12) {
            if busy {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 26, height: 26)
            } else {
                CDStatusSymbol(symbol: symbol, tint: tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(detailTone.style)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            action
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

extension CDStatusLine where Action == EmptyView {
    public init(symbol: String, busy: Bool = false, tint: Color, title: String, detail: String? = nil,
                detailTone: CDTone = .secondary) {
        self.init(symbol: symbol, busy: busy, tint: tint, title: title, detail: detail, detailTone: detailTone) {
            EmptyView()
        }
    }
}

/// The symbol of a status line: it swaps when the state changes, with a bounce on macOS 14 and later.
private struct CDStatusSymbol: View {
    let symbol: String
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let image = Image(systemName: symbol)
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 26, height: 26)
        if reduceMotion {
            image
        } else if #available(macOS 14, *) {
            image
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: symbol)
                .animation(.default, value: symbol)
        } else {
            image
        }
    }
}

/// One dot per step; the current one is a short bar in the accent colour. `current` counts from zero.
public struct CDStepDots: View {
    private let count: Int
    private let current: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    public init(count: Int, current: Int) {
        self.count = count
        self.current = current
    }

    public var body: some View {
        CDGlassCapsule {
            HStack(spacing: 7) {
                ForEach(0..<max(count, 0), id: \.self) { index in
                    Capsule()
                        .fill(index == current ? Color.accentColor
                                               : Color.primary.opacity(contrast == .increased ? 0.45 : 0.18))
                        .frame(width: index == current ? 18 : 7, height: 7)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: current)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Step \(current + 1) of \(count)"))
    }
}

extension View {
    /// Makes a new step fade in and rise 10 pt over 0.4 s whenever `id` changes. Nothing moves with Reduce Motion.
    public func cdStepTransition(id: some Hashable) -> some View {
        modifier(CDStepTransitionModifier(id: id))
    }
}

private struct CDStepTransitionModifier<ID: Hashable>: ViewModifier {
    let id: ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content.id(id)
        } else {
            // A new id is a new view, and a new view starts hidden and settles in.
            Entering { content }.id(id)
        }
    }

    private struct Entering<Inner: View>: View {
        @ViewBuilder let inner: Inner
        @State private var shown = false

        var body: some View {
            inner
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 10)
                .onAppear { withAnimation(.easeOut(duration: 0.4)) { shown = true } }
        }
    }
}
