import Foundation
import ClamDownShared

// ClamDownShared is also built into the helper, which shows no text, so the names people read live here.

extension SensorGroup {
    /// The group's name on screen.
    public var localizedTitle: String {
        switch self {
        case .cpu: String(localized: "CPU")
        case .gpu: String(localized: "GPU")
        case .battery: String(localized: "Battery")
        case .ssd: String(localized: "SSD")
        case .wifi: String(localized: "Wi-Fi")
        case .airflow: String(localized: "Airflow")
        }
    }
}

extension ThermalLevel {
    /// The level's name on screen, capitalized as in the Switch Off When Hot menu.
    public var localizedName: String {
        switch self {
        case .nominal: String(localized: "Nominal")
        case .fair: String(localized: "Fair")
        case .serious: String(localized: "Serious")
        case .critical: String(localized: "Critical")
        }
    }
}

extension String {
    /// Two whole sentences in one message. Localized, so a language that joins sentences without a space can.
    public static func sentences(_ first: String, _ second: String) -> String {
        String(localized: "\(first) \(second)", comment: "Two whole sentences, one after the other.")
    }
}
