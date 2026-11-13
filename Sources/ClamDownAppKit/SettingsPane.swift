import Foundation

/// A page of the Settings window, in sidebar order.
public enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case general, sleep, protection, cooling, appearance, helper, about

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: "General"
        case .sleep: "Sleep"
        case .protection: "Protection"
        case .cooling: "Cooling"
        case .appearance: "Appearance"
        case .helper: "Helper"
        case .about: "About"
        }
    }

    public var symbol: String {
        switch self {
        case .general: "gearshape"
        case .sleep: "moon.zzz"
        case .protection: "shield.lefthalf.filled"
        case .cooling: "fan"
        case .appearance: "paintbrush"
        case .helper: "wrench.and.screwdriver"
        case .about: "info.circle"
        }
    }

    /// The line under the page title. About has none.
    public var subtitle: String {
        switch self {
        case .general: "Startup, notifications and a fresh start."
        case .sleep: "How long ClamDown keeps the Mac awake, and what it does meanwhile."
        case .protection: "When ClamDown lets a Mac in a bag go to sleep."
        case .cooling: "ClamDown takes the fans and cools early, because a closed Mac has little airflow."
        case .appearance: "How ClamDown looks in the menu bar."
        case .helper: "A small background helper with administrator rights changes the sleep setting and drives the fans. It does nothing else."
        case .about: ""
        }
    }

    /// Whether a gap separates this pane from the ones above it in the sidebar.
    public var startsGroup: Bool { self == .about }

    /// The pane stored by this or another version of the app; anything unknown opens General.
    public static func restored(from raw: String?) -> SettingsPane {
        raw.flatMap(SettingsPane.init(rawValue:)) ?? .general
    }
}
