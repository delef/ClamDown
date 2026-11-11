import Foundation
import IOKit

/// Watches the lid through the power management root domain.
/// Any general-interest message makes it re-read `AppleClamshellState`, so it does not depend on message codes.
public final class LiveLidMonitor: LidMonitoring {
    fileprivate var onClose: (@Sendable () -> Void)?
    fileprivate var wasClosed = false
    fileprivate var service: io_service_t = 0
    private var port: IONotificationPortRef?
    private var notification: io_object_t = 0

    public init() {}

    public func start(onClose: @escaping @Sendable () -> Void) {
        stop()
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return }
        self.service = service
        self.onClose = onClose
        wasClosed = Self.isClosed(service)

        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, .main)
        self.port = port
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddInterestNotification(port, service, kIOGeneralInterest, { context, _, _, _ in
            guard let context else { return }
            Unmanaged<LiveLidMonitor>.fromOpaque(context).takeUnretainedValue().lidStateMayHaveChanged()
        }, context, &notification)
        if result != KERN_SUCCESS { stop() }
    }

    public func stop() {
        if notification != 0 {
            IOObjectRelease(notification)
            notification = 0
        }
        if let port {
            IONotificationPortDestroy(port)
            self.port = nil
        }
        if service != 0 {
            IOObjectRelease(service)
            service = 0
        }
        onClose = nil
        wasClosed = false
    }

    fileprivate func lidStateMayHaveChanged() {
        let closed = Self.isClosed(service)
        defer { wasClosed = closed }
        if closed, !wasClosed { onClose?() }
    }

    private static func isClosed(_ service: io_service_t) -> Bool {
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? Bool) ?? false
    }

    deinit { stop() }
}
