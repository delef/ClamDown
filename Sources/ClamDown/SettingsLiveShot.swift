#if DEBUG
import AppKit
import SwiftUI
import ClamDownAppKit
import ClamDownShared

/// Debug builds only: takes the screenshots in `docs/screenshots` and on the site. Each page is shown in a real
/// settings window on screen, because the system draws the sidebar's glass only there, and `screencapture` takes
/// the window with its shadow. The app does not activate; the window only looks active.
///
///     ClamDown -settingsShot <directory> -settingsShotLive YES    the published pages, light and dark, then quits
///     ... -settingsShotPanes cooling,about    these pages instead
///
/// The process that starts it needs Screen & System Audio Recording permission, or every picture comes out empty.
@MainActor
enum SettingsLiveShot {
    /// The pages the README and the site show.
    static let publishedPanes: [SettingsPane] = [.cooling, .protection, .sleep, .general]

    static func shoot(into directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let controller = await SettingsPreview.makeController(showcase: true)
        let updater = Updater(starts: false)
        let only = UserDefaults.standard.string(forKey: "settingsShotPanes")?.split(separator: ",").map(String.init)
        let panes = only.map { names in SettingsPane.allCases.filter { names.contains($0.rawValue) } } ?? publishedPanes
        let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
        var failed = false
        for (appearanceName, appearance) in appearances {
            for pane in panes {
                var selection = pane
                let view = SettingsRootView(
                    controller: controller, notifications: PreviewNotifications(state: .allowed),
                    openSetup: {}, selection: Binding(get: { selection }, set: { selection = $0 }))
                    .environmentObject(updater)
                let url = directory.appendingPathComponent("\(pane.rawValue)-\(appearanceName).png")
                if !(await capture(view, title: pane.title, appearance: appearance, to: url)) { failed = true }
            }
        }
        print(failed ? "some pictures failed; see above" : "wrote the settings screenshots to \(directory.path)")
    }

    /// Shows `view` in a window built as `SettingsWindowController` builds it and captures that window.
    private static func capture<V: View>(_ view: V, title: String, appearance: NSAppearance.Name, to url: URL) async -> Bool {
        let window = ActiveLookingWindow(
            contentRect: NSRect(origin: .zero, size: SettingsWindowController.contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.title = title
        window.appearance = NSAppearance(named: appearance)
        window.isReleasedWhenClosed = false
        window.setContentSize(SettingsWindowController.contentSize)
        window.center()
        window.orderFrontRegardless()
        // Time for the page's tasks to load the readings and for the glass to settle.
        try? await Task.sleep(for: .milliseconds(1500))
        let shot = Process()
        shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        shot.arguments = ["-x", "-l", String(window.windowNumber), url.path]
        var ok = false
        do {
            try shot.run()
            shot.waitUntilExit()
            ok = shot.terminationStatus == 0 && FileManager.default.fileExists(atPath: url.path)
        } catch {
            print("could not start screencapture: \(error)")
        }
        if !ok { print("no picture of \(url.lastPathComponent): screencapture exited \(shot.terminationStatus)") }
        window.orderOut(nil)
        window.contentViewController = nil
        return ok
    }
}

/// A helper that accepts every request and reports ClamDown driving two fans at steady, plausible readings, so
/// the screenshots show a working Mac and the same numbers on every run.
final class ShowcaseHelper: HelperControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false

    func enable(lowPowerOnBattery: Bool) async throws { lock.withLock { enabled = true } }
    func disable() async throws { lock.withLock { enabled = false } }
    func restoreOriginalSettings() async throws {}
    func setLowPowerOnBattery(_ on: Bool) async throws {}
    func heartbeat() async throws -> Bool { lock.withLock { enabled } }
    func isEnabled() async throws -> Bool { lock.withLock { enabled } }
    func setFanPolicy(_ policy: FanPolicy) async throws {}

    func coolingStatus() async throws -> CoolingStatus {
        let groups: [SensorGroup: Double] = [.cpu: 58, .gpu: 52, .battery: 34, .ssd: 41, .wifi: 45, .airflow: 39]
        return CoolingStatus(
            cpuTemperature: 58, hottestCPUTemperature: 71,
            fans: [FanReading(rpm: 4410, minimum: 1200, maximum: 6550, index: 0),
                   FanReading(rpm: 4426, minimum: 1200, maximum: 6550, index: 1)],
            isControlling: true, problem: nil, control: .controlling, systemThermalLevel: .nominal,
            hottestTemperature: 58, hottestGroup: .cpu, groupTemperatures: groups)
    }
}
#endif
