import Foundation
import IOKit

/// How long nobody has touched this Mac's keyboard, trackpad or mouse.
public protocol IdleReading: Sendable {
    /// Nil when it cannot be read. Callers must then assume somebody is there.
    func idleTime() -> Duration?
}

/// Whether somebody is at the Mac, as far as it can tell.
public enum Attendance: Equatable, Sendable {
    /// Someone is there, or it cannot be told. The Mac is left alone.
    case attended
    /// The lid is closed for sleep, but the Mac was touched less than a minute ago. Look again after this long.
    case leaving(Duration)
    /// Closed, quiet for a minute, and no display to work on: in a bag or on a shelf.
    case unattended

    /// A person who closes the lid and walks off stops typing. One who works on a closed Mac does not.
    public static let quietTime: Duration = .seconds(60)

    public init(lid: LidState?, idle: Duration?, externalDisplay: Bool) {
        guard let lid, lid.isClosedForSleep, !externalDisplay, let idle else {
            self = .attended
            return
        }
        self = idle >= Self.quietTime ? .unattended : .leaving(Self.quietTime - idle)
    }
}

/// Reads the time since the last input event from the HID system. Needs no privileges and works for a daemon.
public struct SystemIdle: IdleReading {
    public init() {}

    public func idleTime() -> Duration? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)
        guard let nanoseconds = (value?.takeRetainedValue() as? NSNumber)?.uint64Value else { return nil }
        return .nanoseconds(Int64(clamping: nanoseconds))
    }
}
