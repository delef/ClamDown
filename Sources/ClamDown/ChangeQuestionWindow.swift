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
            alert.accessoryView = pending.question.illustration.map(Self.view)
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { pending.onNew() } else { pending.onOld() }
            self?.isShowing = false
            self?.showNext()
        }
    }

    private static func view(for illustration: ChangeQuestion.Illustration) -> NSView {
        let content: AnyView = switch illustration {
        case .menuBarIcons(let old, let new): AnyView(MenuBarIconsIllustration(styles: [old, new]))
        }
        let host = NSHostingView(rootView: content)
        host.frame.size = host.fittingSize
        return host
    }
}

/// Icon styles side by side, each off and on, with its name.
private struct MenuBarIconsIllustration: View {
    let styles: [MenuBarIconStyle]

    var body: some View {
        HStack(spacing: 32) {
            ForEach(styles, id: \.self) { style in
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        MenuBarIconGlyph(symbol: style.offSymbol)
                        MenuBarIconGlyph(symbol: style.onSymbol)
                    }
                    .scaleEffect(1.6)
                    .frame(height: 32)
                    Text(style.title).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 8)
        .frame(width: 260)
    }
}
