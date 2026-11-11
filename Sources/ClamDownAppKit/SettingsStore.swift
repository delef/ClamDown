import Foundation

public protocol SettingsStoring: AnyObject {
    func load() -> Settings
    /// Throws when the settings could not be stored; the caller must then keep the old settings.
    func save(_ settings: Settings) throws
}

public final class UserDefaultsSettingsStore: SettingsStoring {
    private static let key = "settings.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> Settings {
        guard let data = defaults.data(forKey: Self.key),
              let settings = try? JSONDecoder().decode(Settings.self, from: data) else {
            return Settings()
        }
        return settings.clamped()
    }

    public func save(_ settings: Settings) throws {
        let data = try JSONEncoder().encode(settings)
        defaults.set(data, forKey: Self.key)
    }
}
