/// When a Turn On shows itself in a window. Setting up the helper or waiting for it can take half a minute, and a
/// blinking menu bar icon alone does not say what is going on. The window opens at most once per Turn On, and only
/// a window the Turn On opened itself closes by itself, after the Turn On ended with ClamDown on.
public struct TurnOnProgressWindow: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case none
        case open
        /// Close the window, after a moment in which it says ClamDown is on.
        case close
    }

    /// True once this Turn On has opened the window, even if the user has closed it since.
    private var opened = false
    /// True when the window the Turn On opened is still the one on screen.
    private var owned = false

    public init() {}

    /// Feed every change of the Turn On step, with whether ClamDown is on and whether the window is open now.
    public mutating func update(step: TurnOnStep?, isOn: Bool, windowOpen: Bool) -> Action {
        switch step {
        case .settingUpHelper, .waitingForHelper:
            if owned, !windowOpen { owned = false }
            guard !opened, !windowOpen else { return .none }
            opened = true
            owned = true
            return .open
        case .starting:
            return .none
        case nil:
            defer {
                opened = false
                owned = false
            }
            return owned && windowOpen && isOn ? .close : .none
        }
    }
}
