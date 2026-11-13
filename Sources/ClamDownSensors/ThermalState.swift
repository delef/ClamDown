import Foundation
import ClamDownShared

/// How hot macOS says the Mac is. It takes in sensors ClamDown does not read, such as the battery.
public protocol ThermalStateReading: Sendable {
    func thermalLevel() -> ThermalLevel
}

/// The level macOS reports to this process.
public struct SystemThermalState: ThermalStateReading {
    public init() {}

    public func thermalLevel() -> ThermalLevel {
        ThermalLevel(ProcessInfo.processInfo.thermalState)
    }
}
