/// What the menu bar item and its menu show for a given controller state.
public struct MenuPresentation: Equatable {
    public let symbolName: String
    public let toggleTitle: String
    /// One disabled line under the switch, or nil when there is nothing to say.
    public let statusLine: String?

    public init(symbolName: String, toggleTitle: String, statusLine: String?) {
        self.symbolName = symbolName
        self.toggleTitle = toggleTitle
        self.statusLine = statusLine
    }

    public init(state: SwitchState, notice: String?) {
        switch state {
        case .on:
            self.init(symbolName: "cup.and.saucer.fill", toggleTitle: "Turn Off", statusLine: notice)
        case .off:
            self.init(symbolName: "cup.and.saucer", toggleTitle: "Turn On", statusLine: notice)
        case .needsApproval:
            self.init(symbolName: "cup.and.saucer", toggleTitle: "Turn On",
                      statusLine: "Approve Wakeup in System Settings > Login Items")
        case .failed(let message):
            self.init(symbolName: "cup.and.saucer", toggleTitle: "Turn On", statusLine: message)
        }
    }
}
