import SwiftUI

/// The kit's switch: a 42 x 24 pt track with a 20 pt knob, a little larger than the system switch, which does not
/// grow with `.controlSize` on current macOS. Still a real `Toggle`: it toggles on click, and its accessibility is
/// that of a toggle with its value. The same in the glass and the classic look.
public struct CDSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        let isOn = configuration.isOn
        Button {
            configuration.isOn.toggle()
        } label: {
            Capsule()
                .fill(isOn ? Color.accentColor : Color.primary.opacity(0.15))
                .frame(width: 42, height: 24)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                        .frame(width: 20, height: 20)
                        .padding(2)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.8), value: isOn)
        // The visible control is a button; to assistive technology it is the toggle it stands for.
        .accessibilityRepresentation { Toggle(configuration) }
    }
}

extension ToggleStyle where Self == CDSwitchStyle {
    /// The kit's switch: `.toggleStyle(.cdSwitch)`.
    public static var cdSwitch: CDSwitchStyle { CDSwitchStyle() }
}
