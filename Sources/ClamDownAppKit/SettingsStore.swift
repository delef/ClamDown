import ClamDownShared
import Foundation
import os

private let settingsLog = Logger(subsystem: Identifiers.logSubsystem, category: "settings")

public protocol SettingsStoring: AnyObject {
    func load() -> Settings
    /// Throws when the settings could not be stored; the caller must then keep the old settings.
    func save(_ settings: Settings) throws
}

public final class UserDefaultsSettingsStore: SettingsStoring {
    private static let key = "settings.v1"
    /// Set once the fan curve's 0.1.0 and 0.1.1 defaults were looked at, so a later deliberate 60/85 is left alone.
    private static let fanDefaultsMigratedKey = "settings.fanCurveDefaults.v2"
    /// Set once 0.1.2's defaults were looked at, so a later deliberate 50/75 is left alone.
    private static let fanDefaultsV3MigratedKey = "settings.fanCurveDefaults.v3"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> Settings {
        defer {
            defaults.set(true, forKey: Self.fanDefaultsMigratedKey)
            defaults.set(true, forKey: Self.fanDefaultsV3MigratedKey)
        }
        guard let data = defaults.data(forKey: Self.key),
              var settings = try? JSONDecoder().decode(Settings.self, from: data) else {
            return firstSettings()
        }
        // Stored settings carry every value, so older builds pinned their defaults: 60 and 85 °C up to 0.1.1,
        // 50 and 75 °C in 0.1.2. The curve now starts earlier; untouched old defaults follow it, once each.
        // Only the Standard numbers move; Advanced points are the user's own.
        let start = settings.fanStartTemperature, full = settings.fanFullSpeedTemperature
        let first = !defaults.bool(forKey: Self.fanDefaultsMigratedKey) && start == 60 && full == 85
        let second = !defaults.bool(forKey: Self.fanDefaultsV3MigratedKey) && start == 50 && full == 75
        if first || second {
            let current = Settings()
            settings.fanStartTemperature = current.fanStartTemperature
            settings.fanFullSpeedTemperature = current.fanFullSpeedTemperature
            try? save(settings)
        }
        return settings.clamped()
    }

    /// True when ClamDown ran on this Mac before this launch: an update, not a new install. Read it before `load()`,
    /// which writes keys of its own. 0.1.2 stored settings only once one was changed, so the keys every earlier build
    /// left behind count too: 0.1.2 marked its fan defaults on every launch, and every build since 0.1.0 recorded the
    /// helper it registered and, since 0.1.2, a finished setup. Tells `ChangeQuestionGate` an update from a new install.
    public var hasEarlierInstall: Bool {
        [Self.key, Self.fanDefaultsMigratedKey, UserDefaultsInstalledHelperStore.key, UserDefaultsSetupStore.key]
            .contains { defaults.object(forKey: $0) != nil }
    }

    /// The settings when none are stored: the defaults, with the Cup for a user from an older build, which had it by
    /// default. Stored at once, so a later launch reads this choice instead of guessing again from keys that this
    /// launch writes too.
    private func firstSettings() -> Settings {
        var settings = Settings()
        if hasEarlierInstall { settings.menuBarIcon = .cup }
        do {
            try save(settings)
        } catch {
            // This launch still runs on these settings; the next one decides again, from keys this launch wrote.
            settingsLog.error("The first settings could not be stored: \(error, privacy: .public)")
        }
        return settings
    }

    public func save(_ settings: Settings) throws {
        let data = try JSONEncoder().encode(settings)
        defaults.set(data, forKey: Self.key)
    }
}
