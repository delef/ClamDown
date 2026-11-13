/// What the menu bar item and its menu show for a given controller state.
public struct MenuPresentation: Equatable {
    public let symbolName: String
    public let toggleTitle: String
    /// One disabled line under the switch, or nil when there is nothing to say.
    public let statusLine: String?
    /// True when ClamDown cannot work until the user acts; the icons then carry an attention mark.
    public let needsAttention: Bool

    public init(symbolName: String, toggleTitle: String, statusLine: String?, needsAttention: Bool = false) {
        self.symbolName = symbolName
        self.toggleTitle = toggleTitle
        self.statusLine = statusLine
        self.needsAttention = needsAttention
    }

    public init(state: SwitchState, notice: String?, icon: MenuBarIconStyle = .cup, helperReady: Bool = true) {
        switch state {
        case .on:
            self.init(symbolName: icon.onSymbol, toggleTitle: "Turn Off", statusLine: notice, needsAttention: !helperReady)
        case .off:
            self.init(symbolName: icon.offSymbol, toggleTitle: "Turn On", statusLine: notice, needsAttention: !helperReady)
        case .needsApproval:
            self.init(symbolName: icon.offSymbol, toggleTitle: "Turn On",
                      statusLine: "Approve ClamDown in System Settings > Login Items", needsAttention: true)
        case .failed(let message):
            self.init(symbolName: icon.offSymbol, toggleTitle: "Turn On", statusLine: message, needsAttention: true)
        }
    }
}
