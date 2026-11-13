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
            case .destructive: content.buttonStyle(.glass).foregroundStyle(CDColor.danger)
            }
        } else {
            switch role {
            case .primary: content.buttonStyle(.borderedProminent)
            case .secondary: content.buttonStyle(.bordered)
            case .destructive: content.buttonStyle(.bordered).foregroundStyle(CDColor.danger)
            }
        }
    }
}
