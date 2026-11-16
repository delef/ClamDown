import Foundation

/// A page of the Settings window, in sidebar order.
public enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case general, sleep, protection, cooling, appearance, helper, about

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: String(localized: "General")
        case .sleep: String(localized: "Sleep")
        case .protection: String(localized: "Protection")
        case .cooling: String(localized: "Cooling")
        case .appearance: String(localized: "Appearance")
        case .helper: String(localized: "Helper")
        case .about: String(localized: "About")
        }
    }

    public var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .sleep: "moon.zzz.fill"
        case .protection: "shield.lefthalf.filled"
        case .cooling: "fan.fill"
        case .appearance: "paintbrush.fill"
        case .helper: "wrench.and.screwdriver.fill"
        case .about: "info"
        }
    }

    /// The line under the page title. About has none.
    public var subtitle: String {
        switch self {
        case .general: String(localized: "Startup, notifications and a fresh start.")
        case .sleep: String(localized: "How long ClamDown keeps the Mac awake, and what it does meanwhile.")
        case .protection: String(localized: "When ClamDown lets a Mac in a bag go to sleep.")
        case .cooling: String(localized: "ClamDown takes the fans and cools early, because a closed Mac has little airflow.")
        case .appearance: String(localized: "How ClamDown looks in the menu bar.")
        case .helper: String(localized: "A small background helper with administrator rights changes the sleep setting and drives the fans. It does nothing else.")
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
