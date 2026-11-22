import AppKit
import SwiftUI
import ClamDownAppKit
import ClamDownUI

/// Shows change questions after an update, one window at a time.
///
/// Its own window rather than an `NSAlert`: from macOS 26 an alert puts its icon and title on the left, and an
/// illustration under them then sits apart from them. Here everything is centred (owner, 2026-11-22).
@MainActor
final class ChangeQuestionWindow {
    private struct Pending {
        let question: ChangeQuestion
        let onNew: () -> Void
        let onOld: () -> Void
    }

    private let gate: ChangeQuestionGate
    private var queue: [Pending] = []
    private var isShowing = false

    init(gate: ChangeQuestionGate) {
        self.gate = gate
    }

    /// Asks `question` once, after an update, when `condition` holds (normally: the user still has the old
    /// behaviour); otherwise does nothing. Calls `onNew` or `onOld` with the answer; Escape keeps the old.
    func ask(_ question: ChangeQuestion, showIf condition: Bool,
             onNew: @escaping () -> Void, onOld: @escaping () -> Void = {}) {
        guard gate.shouldAsk(question.id, showIf: condition) else { return }
        queue.append(Pending(question: question, onNew: onNew, onOld: onOld))
        showNext()
    }

    private func showNext() {
        guard !isShowing, !queue.isEmpty else { return }
        isShowing = true
        let pending = queue.removeFirst()
        // On the next turn of the run loop, so a question asked at launch does not hold up the launch.
        DispatchQueue.main.async { [weak self] in
            let takeNew = Self.run(pending.question)
            if takeNew { pending.onNew() } else { pending.onOld() }
            self?.isShowing = false
            self?.showNext()
        }
    }

    /// Shows the window until the user answers; true for the new behaviour.
    private static func run(_ question: ChangeQuestion) -> Bool {
        let answer: (Bool) -> Void = { takeNew in
            NSApp.stopModal(withCode: takeNew ? .OK : .cancel)
        }
        let hosting = NSHostingController(rootView: ChangeQuestionView(question: question, answer: answer))
        // No title bar, which would leave an empty band above the icon: the view draws the window's glass and shape.
        let window = QuestionPanel(contentRect: NSRect(origin: .zero, size: hosting.view.fittingSize),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.setContentSize(hosting.view.fittingSize)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        // Key at once, so the buttons show as active and Return and Escape reach them.
        window.makeKeyAndOrderFront(nil)
        let response = NSApp.runModal(for: window)
        window.orderOut(nil)
        return response == .OK
    }
}

/// A window without a title bar that can still take the keyboard.
private final class QuestionPanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The question: the app icon, the title and the text, the illustration, and the two answers, all centred, on the
/// same glass as a system alert (macOS 26 and later) or on a material before.
private struct ChangeQuestionView: View {
    let question: ChangeQuestion
    /// Called with true for the new behaviour, false for the old one.
    let answer: (Bool) -> Void
    @Environment(\.cdLook) private var look
    private static let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)

    var body: some View {
        VStack(spacing: 16) {
            CDAppIcon(size: 64)
            VStack(spacing: 6) {
                Text(question.title)
                    .font(.headline)
                Text(question.message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            if let illustration = question.illustration {
                switch illustration {
                case .menuBarIcons(let old, let new):
                    MenuBarIconsIllustration(old: old, new: new, answer: answer)
                }
            }
            VStack(spacing: 8) {
                Button { answer(true) } label: {
                    Text(question.newChoice).frame(maxWidth: .infinity)
                }
                .cdButtonStyle(.primary)
                .keyboardShortcut(.defaultAction)
                .cdPointingHand()
                Button { answer(false) } label: {
                    Text(question.oldChoice).frame(maxWidth: .infinity)
                }
                .cdButtonStyle(.secondary)
                .keyboardShortcut(.cancelAction)
                .cdPointingHand()
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(width: 280)
        .background { glass }
    }

    @ViewBuilder private var glass: some View {
        if look == .glass, #available(macOS 26, *) {
            Color.clear.glassEffect(.regular, in: Self.shape)
        } else {
            Self.shape.fill(.regularMaterial)
        }
    }
}

/// The new and the old icon style side by side, the new one first as its button is, each as a card with its off and
/// on look and its name. A card is a button: it answers the question as the button for that side does.
private struct MenuBarIconsIllustration: View {
    let old: MenuBarIconStyle
    let new: MenuBarIconStyle
    /// Called with true for the new style, false for the old one.
    let answer: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            card(new, takeNew: true)
            card(old, takeNew: false)
        }
        .frame(maxWidth: .infinity)
    }

    private func card(_ style: MenuBarIconStyle, takeNew: Bool) -> some View {
        Button { answer(takeNew) } label: {
            VStack(spacing: 8) {
                HStack(spacing: 14) {
                    glyph(style.offSymbol)
                    glyph(style.onSymbol)
                }
                Text(style.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(CardButtonStyle())
        .help(takeNew ? String(localized: "Use this icon") : String(localized: "Keep this icon"))
    }

    /// Drawn at the size it is shown, not scaled afterwards, so it takes its real room in the layout.
    private func glyph(_ symbol: String) -> some View {
        Image(nsImage: MenuBarIconImage.base(symbol: symbol) ?? NSImage())
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: 28, height: 28)
            .foregroundStyle(.primary)
    }
}

/// A card that lightens under the pointer, shows the pointing hand, and darkens while pressed.
private struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Card(label: configuration.label, isPressed: configuration.isPressed)
    }

    /// A view of its own, so it can remember whether the pointer is over it.
    private struct Card: View {
        let label: Configuration.Label
        let isPressed: Bool
        @State private var isHovered = false

        var body: some View {
            label
                .background(.quaternary.opacity(isPressed ? 1 : isHovered ? 0.8 : 0.5),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onHover { isHovered = $0 }
                .cdPointingHand()
        }
    }
}
