import SwiftUI

/// One of several pictured choices, such as a menu bar icon style, drawn as System Settings draws Icon & Widget
/// Style: a picture ringed in the accent colour while it is the chosen one, and its name under it.
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
                    .frame(width: 60, height: 32)
                    .background(shape.fill(.quaternary))
                    .padding(3)
                    .overlay {
                        RoundedRectangle(cornerRadius: CDMetric.choiceTileRadius + 3, style: .continuous)
                            .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2.5)
                    }
                Text(title)
                    .font(.callout)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
