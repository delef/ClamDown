#if DEBUG
import AppKit
import SwiftUI
import ClamDownAppKit
import ClamDownSensors
import ClamDownShared
import ClamDownUI

/// Debug builds only: draws every page of the real settings view to PNG files, light and dark, glass and classic,
/// for a machine where live windows cannot be captured. The helper, settings, notifications and updater are
/// stand-ins, and the menu bar item is not shown.
///
///     ClamDown -settingsShot <directory>    draws every pane, then quits
///     ClamDown -settingsShot <directory> -settingsShotPanes cooling,about    draws only these panes
///
/// The system draws no glass into an offscreen picture, so the sidebar and the glass buttons show their fallback.
@MainActor
enum SettingsPreview {
    /// True when this launch is a settings picture run.
    static var isRequested: Bool { UserDefaults.standard.string(forKey: "settingsShot") != nil }

    /// Returns true when the launch was a settings picture run.
    static func run() -> Bool {
        guard let directory = UserDefaults.standard.string(forKey: "settingsShot") else { return false }
        Task {
            await shoot(into: URL(fileURLWithPath: directory))
            exit(0)
        }
        return true
    }

    private static func makeController() -> ClamDownController {
        var settings = AppSettings()
        // The curve mode shows both temperature sliders.
        settings.fanMode = .curve
        let store = PreviewSettingsStore()
        try? store.save(settings)
        return ClamDownController(
            helper: PreviewHelper(),
            registrar: PreviewRegistrar(state: .ready, registerError: nil),
            monitor: LiveSystemMonitor(),
            settingsStore: store,
            notifier: PreviewNotifier(),
            activity: AppNapActivity(),
            installedHelper: PreviewInstalledHelper(),
            sensors: SMCFanHardware())
    }

    private static func shoot(into directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let controller = makeController()
        let updater = Updater(starts: false)
        let size = CGSize(width: 780, height: 560)
        // Tall pictures show a whole page that scrolls in a window of the real size.
        let tall = CGSize(width: 780, height: 1100)
        let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
        let looks: [(String, CDLook)] = [("glass", .glass), ("classic", .classic)]
        let only = UserDefaults.standard.string(forKey: "settingsShotPanes")?.split(separator: ",").map(String.init)
        let panes = SettingsPane.allCases.filter { only?.contains($0.rawValue) ?? true }
        for (appearanceName, appearance) in appearances {
            for (lookName, look) in looks {
                for pane in panes {
                    for (suffix, frame) in [("", size), ("-tall", tall)] {
                        var selection = pane
                        let view = SettingsRootView(
                            controller: controller, notifications: PreviewNotifications(state: .allowed),
                            openSetup: {}, selection: Binding(get: { selection }, set: { selection = $0 }))
                            .environmentObject(updater)
                            .environment(\.cdLook, look)
                            // The window's own background is not part of the picture.
                            .background(Color(nsColor: .windowBackgroundColor))
                        await draw(view, size: frame, appearance: appearance,
                                   to: directory.appendingPathComponent("\(lookName)-\(appearanceName)-\(pane.rawValue)\(suffix).png"))
                    }
                }
            }
        }
        print("wrote the settings pages to \(directory.path)")
    }

    private static func draw<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name, to url: URL) async {
        // Far off screen: the view must sit in a window for its tasks to run, but nobody should see it.
        let window = ActiveLookingWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
                                         styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(700))
        hosting.layoutSubtreeIfNeeded()
        if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
        window.contentView = nil
        window.orderOut(nil)
    }
}
#endif
