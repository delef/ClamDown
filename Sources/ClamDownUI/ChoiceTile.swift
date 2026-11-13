import SwiftUI

/// A tile that picks one of several choices, such as a menu bar icon style: a picture over a caption, ringed in the
/// accent colour while it is the chosen one.
public struct CDChoiceTile<Content: View>: View {
    private let title: String
    private let isSelected: Bool
    private let action: () -> Void
    private let content: Content

    public init(_ title: String, isSelected: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.title = title
        self.isSelected = isSelected
        self.action = action
        self.content = content()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: CDMetric.choiceTileRadius, style: .continuous)
        Button(action: action) {
            VStack(spacing: 6) {
                content
                    .frame(height: 20)
                Text(title).font(.caption)
            }
            .frame(width: 72, height: 58)
            .background(shape.fill(isSelected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05)))
            .overlay(shape.strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
