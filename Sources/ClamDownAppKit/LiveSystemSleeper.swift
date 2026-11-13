import Foundation

/// Puts the Mac to sleep with `pmset sleepnow`. The logged-in user may do that; no helper is needed.
public struct LiveSystemSleeper: SystemSleeping {
    public init() {}

    public func sleepNow() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["sleepnow"]
        try? process.run()
    }
}
