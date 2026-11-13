import Foundation

/// Remembers that the user finished setup, so the assistant does not open at every launch.
public protocol SetupStoring: AnyObject {
    var completed: Bool { get set }
}

public final class UserDefaultsSetupStore: SetupStoring {
    private static let key = "setup.completed.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var completed: Bool {
        get { defaults.bool(forKey: Self.key) }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}
