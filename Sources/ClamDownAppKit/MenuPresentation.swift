/// The one thing the menu offers to press when ClamDown cannot work as it is.
public enum MenuRecovery: Equatable, Sendable {
    /// The helper is not allowed or not registered: the setup assistant leads through it.
    case finishSetup
    /// Switching on failed although macOS allows the helper: registering it afresh fixes most of these.
    case reinstallHelper
}

/// What the menu bar item and its menu show for a given controller state.
public struct MenuPresentation: Equatable {
    public let symbolName: String
    public let toggleTitle: String
    /// One disabled line under the switch, or nil when there is nothing to say.
    public let statusLine: String?
    /// True when ClamDown cannot work until the user acts; the icons then carry an attention mark.
    public let needsAttention: Bool
    /// What to offer under the status line, or nil when nothing is wrong.
    public let recovery: MenuRecovery?
    /// True while ClamDown keeps the Mac awake.
    public let isOn: Bool
    /// A line while ClamDown has stopped controlling the fans. It carries no attention mark: the Mac still stays
    /// awake and macOS cools it.
    public let coolingLine: String?

    public init(symbolName: String, toggleTitle: String, statusLine: String?, needsAttention: Bool = false,
                recovery: MenuRecovery? = nil, isOn: Bool = false, coolingLine: String? = nil) {
        self.isOn = isOn
        self.coolingLine = coolingLine
        self.symbolName = symbolName
        self.toggleTitle = toggleTitle
        self.statusLine = statusLine
        self.needsAttention = needsAttention
        self.recovery = recovery
    }

    public init(state: SwitchState, notice: String?, icon: MenuBarIconStyle = .lid, helperReady: Bool = true,
                coolingLine: String? = nil) {
        let setup: MenuRecovery? = helperReady ? nil : .finishSetup
        switch state {
        case .on:
            self.init(symbolName: icon.onSymbol, toggleTitle: "Turn Off", statusLine: notice,
                      needsAttention: !helperReady, recovery: setup, isOn: true, coolingLine: coolingLine)
        case .off:
            self.init(symbolName: icon.offSymbol, toggleTitle: "Turn On", statusLine: notice,
                      needsAttention: !helperReady, recovery: setup)
        case .needsApproval:
            self.init(symbolName: icon.offSymbol, toggleTitle: "Turn On",
                      statusLine: "Approve ClamDown in System Settings > Login Items", needsAttention: true,
                      recovery: .finishSetup)
        case .failed(let message):
            // The switch says what pressing it does now: the same thing once more.
            self.init(symbolName: icon.offSymbol, toggleTitle: "Try Again", statusLine: message, needsAttention: true,
                      recovery: setup ?? .reinstallHelper)
        }
    }

    /// What VoiceOver reads for the menu bar item: the app, whether it is on, and whether it needs the user.
    /// The icon alone says this only by its shape, and the menu bar item is the app's only way in.
    public var accessibilityLabel: String {
        "ClamDown, " + (isOn ? "on" : "off") + (needsAttention ? ", needs attention" : "")
    }
}

/// How often the app asks macOS whether the helper is still allowed. macOS sends no notice when that changes.
public enum HelperRefreshPace {
    /// Seconds between looks. While something waits on the user, they are probably in System Settings right now,
    /// and the menu and the icon should follow within seconds of their click.
    public static func interval(needsAttention: Bool) -> Double {
        needsAttention ? 2 : 30
    }
}
