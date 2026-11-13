import SwiftUI

/// Content on a small glass capsule (macOS 26 and later), or on nothing before. For navigation-level controls
/// such as the step dots; never for text or cards.
public struct CDGlassCapsule<Content: View>: View {
    private let content: Content
    @Environment(\.cdLook) private var look

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        let padded = content.padding(.horizontal, 12).padding(.vertical, 8)
        if look == .glass, #available(macOS 26, *) {
            padded.glassEffect(.regular, in: .capsule)
        } else {
            padded
        }
    }
}
