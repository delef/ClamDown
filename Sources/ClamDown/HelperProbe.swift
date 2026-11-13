#if DEBUG
import Foundation
import ServiceManagement

/// Debug builds only: removes the helper, registers it again and prints how macOS answered and when.
/// It exists because macOS refuses a registration that follows a removal too closely, and only a run
/// against the real system shows how long "too closely" is.
///
///     ClamDown -helperProbe <milliseconds to wait between the removal and the first registration>
///              [-helperProbeEvery <milliseconds between registration attempts, 250 by default>]
@MainActor
enum HelperProbe {
    static var isRequested: Bool {
        UserDefaults.standard.string(forKey: "helperProbe") != nil
    }

    static func run(plistName: String) async {
        let wait = UserDefaults.standard.integer(forKey: "helperProbe")
        let service = SMAppService.daemon(plistName: plistName)
        let start = Date()
        func log(_ text: String) {
            print(String(format: "%7.3f  %@", Date().timeIntervalSince(start), text))
        }

        log("status \(service.status.rawValue)")
        do {
            try await service.unregister()
            log("removed, status \(service.status.rawValue)")
        } catch {
            log("removal failed: \((error as NSError).code), status \(service.status.rawValue)")
        }
        // No status reads while waiting: the wait is meant to be quiet.
        try? await Task.sleep(for: .milliseconds(wait))
        let pause = max(UserDefaults.standard.integer(forKey: "helperProbeEvery"), 250)
        for attempt in 1...8 {
            do {
                try service.register()
                log("registration \(attempt) accepted, status \(service.status.rawValue)")
                return
            } catch {
                log("registration \(attempt) refused: \((error as NSError).code), status \(service.status.rawValue)")
            }
            try? await Task.sleep(for: .milliseconds(pause))
        }
    }
}
#endif
