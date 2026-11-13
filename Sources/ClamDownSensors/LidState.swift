import Foundation
import IOKit

/// The lid as macOS's power management sees it.
public struct LidState: Equatable, Sendable {
    public var closed: Bool
    /// True when closing the lid puts this Mac to sleep. macOS says false while a closed Mac is meant to keep
    /// running, for example in front of an external display.
    public var closingCausesSleep: Bool

    public init(closed: Bool, closingCausesSleep: Bool) {
        self.closed = closed
        self.closingCausesSleep = closingCausesSleep
    }

    /// The lid is closed and macOS would have this Mac asleep: nobody is using it, it may be in a bag.
    public var isUnattended: Bool { closed && closingCausesSleep }
}

public protocol LidReading: Sendable {
    /// Nil when the state cannot be read, as on a Mac without a lid. Callers must then treat the Mac as attended.
    func lid() -> LidState?
}

/// Reads the lid from the power management root domain. Needs no privileges.
public struct SystemLid: LidReading {
    public init() {}

    public func lid() -> LidState? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let closed = Self.flag("AppleClamshellState", of: service),
              let closingCausesSleep = Self.flag("AppleClamshellCausesSleep", of: service) else { return nil }
        return LidState(closed: closed, closingCausesSleep: closingCausesSleep)
    }

    private static func flag(_ name: String, of service: io_service_t) -> Bool? {
        IORegistryEntryCreateCFProperty(service, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
    }
}
