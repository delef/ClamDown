import AppKit
import SwiftUI
import ClamDownAppKit

/// Shows change questions after an update, one window at a time.
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
    /// behaviour); otherwise does nothing. Calls `onNew` or `onOld` with the answer; closing the window keeps the old.
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
            let alert = NSAlert()
            alert.messageText = pending.question.title
            alert.informativeText = pending.question.message
            alert.addButton(withTitle: pending.question.newChoice)
            alert.addButton(withTitle: pending.question.oldChoice)
            if let illustration = pending.question.illustration {
                Self.attach(illustration, to: alert)
            }
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            // A click on the illustration ends the modal session without a button, so the window is closed here.
            alert.window.orderOut(nil)
            if response == .alertFirstButtonReturn { pending.onNew() } else { pending.onOld() }
            self?.isShowing = false
            self?.showNext()
        }
    }

    /// Puts the illustration under the text, as wide as the text, so it is centred in the window whatever width
    /// this macOS gives an alert. Clicking the old or the new side answers as its button does.
    private static func attach(_ illustration: ChangeQuestion.Illustration, to alert: NSAlert) {
        let answer: (Bool) -> Void = { takeNew in
            NSApp.stopModal(withCode: takeNew ? .alertFirstButtonReturn : .alertSecondButtonReturn)
        }
        let content: AnyView = switch illustration {
        case .menuBarIcons(let old, let new): AnyView(MenuBarIconsIllustration(old: old, new: new, answer: answer))
        }
        let host = NSHostingView(rootView: content)
        host.frame.size = host.fittingSize
        alert.accessoryView = host
        alert.layout()
        let text = alert.window.contentView.flatMap { textWidth(in: $0, matching: alert.informativeText) }
        if let text, text > host.frame.width {
            host.frame.size.width = text
            alert.layout()
        }
    }

    /// The width of the alert's text: the field that shows `string`.
    private static func textWidth(in view: NSView, matching string: String) -> CGFloat? {
        if let field = view as? NSTextField, field.stringValue == string { return field.frame.width }
        for subview in view.subviews {
            if let width = textWidth(in: subview, matching: string) { return width }
        }
        return nil
    }
}

/// The old and the new icon style side by side, each as a card with its off and on look and its name, centred in
/// the space given. A card is a button: it answers the question as the window's button for that side does.
private struct MenuBarIconsIllustration: View {
    let old: MenuBarIconStyle
    let new: MenuBarIconStyle
    /// Called with true for the new style, false for the old one.
    let answer: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            card(old, takeNew: false)
            card(new, takeNew: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
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
            .frame(width: 104)
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

/// A card that lightens under the pointer and darkens while pressed.
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
        }
    }
}
