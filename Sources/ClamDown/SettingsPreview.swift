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
///     ... -settingsShotNoTall YES    skips the tall pictures; -settingsShotWindow YES draws in a titled window
///
/// The system draws no glass into an offscreen picture, so the sidebar and the glass buttons show their fallback.
@MainActor
enum SettingsPreview {
    /// True when this launch is a settings picture run.
    static var isRequested: Bool { UserDefaults.standard.string(forKey: "settingsShot") != nil }

    /// Returns true when the launch was a settings picture run.
    static func run() -> Bool {
        guard let directory = UserDefaults.standard.string(forKey: "settingsShot") else { return false }
        // No Dock icon and no activation: the pictures are drawn in windows far off screen, and nothing shows.
        NSApp.setActivationPolicy(.accessory)
        Task {
            await shoot(into: URL(fileURLWithPath: directory))
            exit(0)
        }
        return true
    }

    private static func makeController() -> ClamDownController {
        var settings = AppSettings()
        // Fan control on with the Standard curve; the Cooling page is also drawn in Advanced and switched off.
        settings.fanControlEnabled = true
        settings.fanCurveMode = .standard
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
        // The About page in each state of the update check; the other pages ignore it.
        let updateStates: [(String, UpdateStatus)] = [
            ("", .upToDate(lastCheck: Date().addingTimeInterval(-3 * 3600))),
            ("-never", .upToDate(lastCheck: nil)),
            ("-available", .available("0.1.4")),
            ("-checking", .checking),
        ]
        let size = CGSize(width: 780, height: 560)
        // Tall pictures show a whole page that scrolls in a window of the real size.
        let tall = CGSize(width: 780, height: 1100)
        let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
        let noTall = UserDefaults.standard.bool(forKey: "settingsShotNoTall")
        let looks: [(String, CDLook)] = [("glass", .glass), ("classic", .classic)]
        let only = UserDefaults.standard.string(forKey: "settingsShotPanes")?.split(separator: ",").map(String.init)
        let panes = SettingsPane.allCases.filter { only?.contains($0.rawValue) ?? true }
        // The Cooling page in each of its forms; the other pages have one.
        let base = controller.settings
        var advanced = base
        advanced.fanCurveMode = .advanced
        advanced.fanAdvancedPoints = [FanPoint(temperature: 45, speed: 0), FanPoint(temperature: 55, speed: 18),
                                      FanPoint(temperature: 65, speed: 40), FanPoint(temperature: 74, speed: 72),
                                      FanPoint(temperature: 82, speed: 100)]
        var off = base
        off.fanControlEnabled = false
        let coolingForms: [(String, AppSettings)] = [("", base), ("-advanced", advanced), ("-off", off)]
        for (appearanceName, appearance) in appearances {
            for (lookName, look) in looks {
                for pane in panes {
                    for (form, settings) in (pane == .cooling ? coolingForms : [("", base)]) {
                    if controller.settings != settings { await controller.updateSettings(settings) }
                    for (state, status) in updateStates where pane == .about || state.isEmpty {
                    updater.previewStatus = status
                    for (suffix, frame) in (noTall ? [("", size)] : [("", size), ("-tall", tall)]) {
                        var selection = pane
                        let view = SettingsRootView(
                            controller: controller, notifications: PreviewNotifications(state: .allowed),
                            openSetup: {}, selection: Binding(get: { selection }, set: { selection = $0 }))
                            .environmentObject(updater)
                            .environment(\.cdLook, look)
                            // The window's own background is not part of the picture.
                            .background(Color(nsColor: .windowBackgroundColor))
                        let name = "\(lookName)-\(appearanceName)-\(pane.rawValue)\(form)\(state)\(suffix).png"
                        await draw(view, size: frame, appearance: appearance, to: directory.appendingPathComponent(name))
                    }
                    }
                    }
                }
            }
        }
        print("wrote the settings pages to \(directory.path)")
    }

    private static func draw<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name, to url: URL) async {
        // Far off screen: the view must sit in a window for its tasks to run, but nobody should see it.
        // With -settingsShotWindow YES the window is a titled one with the hosting controller the real window has,
        // so the page gets the title bar and toolbar areas the real window gives it.
        let titled = UserDefaults.standard.bool(forKey: "settingsShotWindow")
        let window = ActiveLookingWindow(
            contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
            styleMask: titled ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.borderless],
            backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.isReleasedWhenClosed = false
        let hosting: NSView
        if titled {
            let controller = NSHostingController(rootView: view)
            controller.sizingOptions = []
            window.contentViewController = controller
            window.setContentSize(size)
            window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            hosting = controller.view
        } else {
            let plain = NSHostingView(rootView: view)
            plain.frame = NSRect(origin: .zero, size: size)
            window.contentView = plain
            hosting = plain
        }
        window.orderFrontRegardless()
        let delay = UserDefaults.standard.integer(forKey: "settingsShotDelay")
        try? await Task.sleep(for: .milliseconds(delay > 0 ? delay : 700))
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
