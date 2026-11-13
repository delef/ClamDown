import Foundation
import SwiftUI

/// Which look the kit draws. Decided once: macOS 26 and later get the system's Liquid Glass on navigation and
/// controls, earlier versions get the classic bordered controls. Screens never test the macOS version themselves.
public enum CDLook: Equatable, Sendable {
    case glass
    case classic

    /// The look for a macOS major version. `forceClassic` is the debug switch that shows the old look on a new Mac.
    public static func resolve(osMajorVersion: Int, forceClassic: Bool) -> CDLook {
        if forceClassic { return .classic }
        return osMajorVersion >= 26 ? .glass : .classic
    }

    /// The look of this Mac. In a debug build, `-classicLook YES` forces `.classic`.
    public static var current: CDLook {
        #if DEBUG
        let forceClassic = UserDefaults.standard.bool(forKey: "classicLook")
        #else
        let forceClassic = false
        #endif
        return resolve(osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                       forceClassic: forceClassic)
    }
}

private struct CDLookKey: EnvironmentKey {
    static var defaultValue: CDLook { CDLook.current }
}

extension EnvironmentValues {
    /// The look the kit's components draw. Defaults to the look of this Mac; a gallery or test may override it.
    public var cdLook: CDLook {
        get { self[CDLookKey.self] }
        set { self[CDLookKey.self] = newValue }
    }
}
