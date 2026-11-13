import Foundation

public protocol SettingsStoring: AnyObject {
    func load() -> Settings
    /// Throws when the settings could not be stored; the caller must then keep the old settings.
    func save(_ settings: Settings) throws
}

public final class UserDefaultsSettingsStore: SettingsStoring {
    private static let key = "settings.v1"
    /// Set once the fan curve's old defaults were looked at, so a later deliberate 60/85 is left alone.
    private static let fanDefaultsMigratedKey = "settings.fanCurveDefaults.v2"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> Settings {
        defer { defaults.set(true, forKey: Self.fanDefaultsMigratedKey) }
        guard let data = defaults.data(forKey: Self.key),
              var settings = try? JSONDecoder().decode(Settings.self, from: data) else {
            return Settings()
        }
        // Stored settings carry every value, so builds up to 0.1.1 pinned their defaults of 60 and 85 °C.
        // The curve now starts earlier; untouched old defaults follow it, once.
        if !defaults.bool(forKey: Self.fanDefaultsMigratedKey),
           settings.fanStartTemperature == 60, settings.fanFullSpeedTemperature == 85 {
            let current = Settings()
            settings.fanStartTemperature = current.fanStartTemperature
            settings.fanFullSpeedTemperature = current.fanFullSpeedTemperature
            try? save(settings)
        }
        return settings.clamped()
    }

    public func save(_ settings: Settings) throws {
        let data = try JSONEncoder().encode(settings)
        defaults.set(data, forKey: Self.key)
    }
}
