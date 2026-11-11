import Foundation

/// Remembers which helper binary this app last registered, so an update is noticed on the next switch-on.
public protocol InstalledHelperStoring: AnyObject {
    /// Fingerprint of the helper binary registered last. Nil when none is recorded.
    var fingerprint: String? { get set }
}

public final class UserDefaultsInstalledHelperStore: InstalledHelperStoring {
    private static let key = "installedHelper.fingerprint.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var fingerprint: String? {
        get { defaults.string(forKey: Self.key) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Self.key)
            } else {
                defaults.removeObject(forKey: Self.key)
            }
        }
    }
}
