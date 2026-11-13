import SwiftUI

/// What a button is for. The kit decides how each role looks in each look.
public enum CDButtonRole: Sendable {
    /// The one main action of a view.
    case primary
    /// Any other action.
    case secondary
    /// An action that removes or undoes something: a plain button with a red label.
    case destructive
}

extension View {
    /// Styles a `Button` for its role: glass capsules on macOS 26 and later, bordered buttons before.
    /// The size comes from the caller's `.controlSize`.
    public func cdButtonStyle(_ role: CDButtonRole) -> some View {
        modifier(CDButtonStyleModifier(role: role))
    }
}

private struct CDButtonStyleModifier: ViewModifier {
    let role: CDButtonRole
    @Environment(\.cdLook) private var look

    @ViewBuilder
    func body(content: Content) -> some View {
        if look == .glass, #available(macOS 26, *) {
            switch role {
            case .primary: content.buttonStyle(.glassProminent)
            case .secondary: content.buttonStyle(.glass)
            case .destructive: content.buttonStyle(CDDestructiveButtonStyle())
            }
        } else {
            switch role {
            case .primary: content.buttonStyle(.borderedProminent)
            case .secondary: content.buttonStyle(.bordered)
            case .destructive: content.buttonStyle(CDDestructiveButtonStyle())
            }
        }
    }
}

/// A secondary button whose label is red. The colour is set on the label inside the button, so it survives the
/// system style, which otherwise draws the label in its own colour.
private struct CDDestructiveButtonStyle: PrimitiveButtonStyle {
    @Environment(\.cdLook) private var look
    @Environment(\.isEnabled) private var isEnabled

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        let button = Button(action: configuration.trigger) {
            configuration.label.foregroundStyle(CDColor.danger.opacity(isEnabled ? 1 : 0.4))
        }
        if look == .glass, #available(macOS 26, *) {
            button.buttonStyle(.glass)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}
