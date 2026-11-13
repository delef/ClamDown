import AppKit
import Foundation
import IOKit.ps

/// Watches power source, battery level, thermal state and wake from sleep.
/// Every event just says "something changed"; the controller re-reads `snapshot()`.
public final class LiveSystemMonitor: SystemMonitoring {
    fileprivate var onChange: (@Sendable () -> Void)?
    private var powerSource: CFRunLoopSource?
    private var observers: [NSObjectProtocol] = []

    public init() {}

    public func snapshot() -> SystemSnapshot {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        let descriptions = sources.compactMap {
            IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
        }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let power = PowerSnapshotMapper.map(providingSource: providing, descriptions: descriptions)
        return SystemSnapshot(
            batteryPercent: power.batteryPercent,
            isOnBattery: power.isOnBattery,
            thermal: Self.thermalLevel()
        )
    }

    private static func thermalLevel() -> ThermalLevel {
        #if DEBUG
        // Debug builds only: a Mac cannot be made hot on demand, so the heat cut-off is tested with
        //     defaults write <bundle id> debugThermalLevel serious
        // and `defaults delete` afterwards. Release builds do not contain this.
        if let name = UserDefaults.standard.string(forKey: "debugThermalLevel"), let level = ThermalLevel(name: name) {
            return level
        }
        #endif
        return ThermalLevel(ProcessInfo.processInfo.thermalState)
    }

    public func start(onChange: @escaping @Sendable () -> Void) {
        stop()
        self.onChange = onChange

        let context = Unmanaged.passUnretained(self).toOpaque()
        let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<LiveSystemMonitor>.fromOpaque(context).takeUnretainedValue().onChange?()
        }, context).takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        powerSource = source

        observers.append(NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { _ in onChange() })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in onChange() })
    }

    public func stop() {
        if let powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes)
            self.powerSource = nil
        }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        onChange = nil
    }

    deinit { stop() }
}
