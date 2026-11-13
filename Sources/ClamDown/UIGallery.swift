#if DEBUG
import AppKit
import SwiftUI
import ClamDownAppKit
import ClamDownShared
import ClamDownUI

/// Debug builds only: one window showing every component of the UI kit in every state, to check the look by eye.
///
///     ClamDown -uiGallery YES                     opens the gallery
///     ClamDown -uiGallery YES -classicLook YES    the same in the classic look of macOS 13 to 15
///     ClamDown -uiGallery YES -galleryAppearance dark|light    forces the appearance of the app
///     ClamDown -uiGallery YES -galleryShot <name.png>    draws every block of the gallery into <name>.<n>-<block>.png and quits; for a
///                                                         machine where the screen cannot be captured. The system
///                                                         glass may not show in such a picture.
@MainActor
enum UIGallery {
    private static var window: NSWindow?

    /// True when this launch is a gallery run.
    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "uiGallery") }

    /// Returns true when the gallery took over the launch.
    static func run() -> Bool {
        guard isRequested else { return false }
        switch UserDefaults.standard.string(forKey: "galleryAppearance") {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        if let path = UserDefaults.standard.string(forKey: "galleryShot") {
            // No Dock icon and no activation, whatever the stored Dock setting says: nothing shows.
            NSApp.setActivationPolicy(.accessory)
            Task {
                await shoot(to: URL(fileURLWithPath: path))
                exit(0)
            }
            return true
        }
        // With no menu bar item the window is the whole app: closing it ends the run.
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "ClamDown UI Gallery"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: GalleryView())
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
        self.window = window
        return true
    }

    private static func shoot(to url: URL) async {
        // One picture per block: a single tall picture of the whole gallery does not draw reliably.
        for (index, block) in GalleryContent.blocks.enumerated() {
            let size = NSSize(width: 900, height: block.height + 70)
            let window = ActiveLookingWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
                                             styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let root = VStack(alignment: .leading, spacing: 12) {
                Text("Look: \(CDLook.current == .glass ? "glass" : "classic")").font(.caption).foregroundStyle(.secondary)
                block.view
            }
            .padding(24).frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            let hosting = NSHostingView(rootView: root)
            window.contentView = hosting
            window.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(600))
            hosting.layoutSubtreeIfNeeded()
            if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let file = url.deletingPathExtension().appendingPathExtension("\(index + 1)-\(block.name).png")
                try? bitmap.representation(using: .png, properties: [:])?.write(to: file)
                print("wrote \(file.path)")
            }
            window.orderOut(nil)
        }
    }
}

private struct GalleryView: View {
    var body: some View {
        ScrollView { GalleryContent() }
            .frame(minWidth: 700, minHeight: 500)
    }
}

private struct GalleryContent: View {
    @Environment(\.cdLook) private var look

    /// The blocks of the gallery, with the height each needs.
    @MainActor static var blocks: [(name: String, height: CGFloat, view: AnyView)] { [
        ("buttons", 190, AnyView(GalleryBlock("Buttons") { ButtonsGallery() })),
        ("parts", 190, AnyView(GalleryBlock("Brand tile, app icon, status dot") { SmallPartsGallery() })),
        ("shell", 480, AnyView(GalleryBlock("Settings shell (sidebar, brand row, pages)") { ShellGallery().frame(height: 440) })),
        ("page", 800, AnyView(GalleryBlock("Settings page") { SettingsPageGallery().frame(height: 760) })),
        ("setup", 820, AnyView(GalleryBlock("Setup (background, step icons, header, card, status lines, dots)") { SetupGallery() })),
        ("chart", 680, AnyView(GalleryBlock("Fan curve chart (Standard and Advanced, light and dark)") { ChartGallery() })),
    ] }

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            Text("Look: \(look == .glass ? "glass" : "classic")").font(.headline)
            ForEach(Self.blocks.indices, id: \.self) { Self.blocks[$0].view }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GalleryBlock<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold())
            content
        }
    }
}

private struct ButtonsGallery: View {
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 14) {
            ForEach([(ControlSize.regular, "Regular"), (.large, "Large")], id: \.1) { size, name in
                GridRow {
                    Text(name).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                    HStack(spacing: 12) {
                        Button("Primary") {}.cdButtonStyle(.primary)
                        Button("Secondary") {}.cdButtonStyle(.secondary)
                        Button("Remove") {}.cdButtonStyle(.destructive)
                    }
                    HStack(spacing: 12) {
                        Button("Primary") {}.cdButtonStyle(.primary)
                        Button("Secondary") {}.cdButtonStyle(.secondary)
                        Button("Remove") {}.cdButtonStyle(.destructive)
                    }
                    .disabled(true)
                }
                .controlSize(size)
            }
            GridRow {
                Text("")
                Text("Enabled").font(.caption).foregroundStyle(.secondary)
                Text("Disabled").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SmallPartsGallery: View {
    var body: some View {
        HStack(alignment: .center, spacing: 32) {
            CDBrandTile(symbol: "gearshape")
            CDBrandTile(symbol: "fan", size: 96)
            CDAppIcon(size: 64)
            CDAppIcon(size: 64, glow: true)
            HStack(spacing: 14) {
                CDStatusDot(CDColor.success)
                CDStatusDot(CDColor.warning)
                CDStatusDot(CDColor.danger)
                CDStatusDot(.secondary)
            }
        }
        .padding(.vertical, 20)
    }
}

private enum GalleryPane: String, CaseIterable {
    case general, sleep, about
}

private struct ShellGallery: View {
    @State private var pane = GalleryPane.general
    @State private var on = true

    var body: some View {
        CDSettingsShell(
            items: [
                CDSidebarItem(id: GalleryPane.general, title: "General", symbol: "gearshape"),
                CDSidebarItem(id: GalleryPane.sleep, title: "Sleep", symbol: "moon.zzz"),
                CDSidebarItem(id: GalleryPane.about, title: "About", symbol: "info.circle", startsGroup: true),
            ],
            selection: $pane,
            brand: {
                HStack(spacing: 10) {
                    CDAppIcon(size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("ClamDown").fontWeight(.semibold)
                        HStack(spacing: 5) {
                            CDStatusDot(CDColor.success)
                            Text("On until 7:26 PM").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            },
            detail: { pane in
                CDSettingsPage(title: pane.rawValue.capitalized, subtitle: "What this page is for.", symbol: "gearshape") {
                    CDSection("Section") {
                        CDSwitchRow("A switch", detail: "Its explanation.", isOn: $on)
                    }
                }
            })
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)) }
    }
}

private struct SettingsPageGallery: View {
    @State private var on = true
    @State private var off = false

    var body: some View {
        CDSettingsPage(title: "General", subtitle: "Starting, notifying and showing ClamDown.", symbol: "gearshape") {
            CDSection("Switches") {
                CDSwitchRow("Show in Dock", detail: "Keeps ClamDown in the Dock as well as the menu bar.", isOn: $on)
                CDSwitchRow("A switch that is off", isOn: $off)
                CDRow("System switch, for comparison",
                      detail: "The rows above use the kit's switch; this one is the system's plain .switch toggle.") {
                    Toggle("System", isOn: $on).labelsHidden().toggleStyle(.switch)
                }
                CDSwitchRow("A row with a three-line explanation",
                            detail: "This explanation is long on purpose. It has to wrap onto a second and a third line "
                                + "and never be cut off, at any text size, next to a control that keeps its place at "
                                + "the trailing edge of the row while the words flow around it.",
                            isOn: $on)
            }
            CDSection("Values") {
                CDValueRow("Helper", value: "Allowed", tone: .success)
                CDValueRow("Temperature", value: "61 °C")
                CDValueRow("Fan", value: "Not available", tone: .danger)
                CDRow("A row with a button", detail: "Any control goes on the right.") {
                    Button("Check Now") {}.cdButtonStyle(.secondary)
                }
                CDNote("Heads up: this is what a warning note looks like inside a section.", tone: .warning)
                CDNote("And a plain secondary note.")
            }
        }
    }
}

/// The Cooling page's chart in both modes and both appearances. The points can be dragged here too.
private struct ChartGallery: View {
    var body: some View {
        Grid(horizontalSpacing: 16, verticalSpacing: 16) {
            GridRow {
                ChartSample(mode: .standard, scheme: .light)
                ChartSample(mode: .standard, scheme: .dark)
            }
            GridRow {
                ChartSample(mode: .advanced, scheme: .light)
                ChartSample(mode: .advanced, scheme: .dark)
            }
        }
    }
}

private struct ChartSample: View {
    let mode: FanCurveMode
    let scheme: ColorScheme
    @State private var points: [FanPoint]

    init(mode: FanCurveMode, scheme: ColorScheme) {
        self.mode = mode
        self.scheme = scheme
        // Advanced ends below full speed, so the floor lifts it near the hot end and the asked-for line shows.
        _points = State(initialValue: mode == .standard
            ? StandardCurve.points(start: 50, full: 75)
            : [FanPoint(temperature: 45, speed: 0), FanPoint(temperature: 55, speed: 18),
               FanPoint(temperature: 65, speed: 40), FanPoint(temperature: 74, speed: 72),
               FanPoint(temperature: 80, speed: 80)])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(mode == .standard ? "Standard, Now 58 \u{00B0}C, rpm known" : "Advanced, Now 92 \u{00B0}C, no rpm"), "
                + "\(scheme == .dark ? "dark" : "light"), point \(mode == .standard ? 2 : 3) labelled")
                .font(.caption).foregroundStyle(.secondary)
            FanCurveChart(points: points, mode: mode, nowTemperature: mode == .standard ? 58 : 92,
                          firstFan: mode == .standard ? FanReading(rpm: 2310, minimum: 1200, maximum: 5800) : nil,
                          labelledPoint: mode == .standard ? 1 : 2) { index, point in
                points = FanCurveEditor.moved(points, mode: mode, dragging: index, to: point)
            }
        }
        .padding(CDMetric.cardInset)
        .background(RoundedRectangle(cornerRadius: CDMetric.cardRadius, style: .continuous).fill(CDColor.cardBackground))
        .environment(\.colorScheme, scheme)
        .frame(width: 410)
    }
}

private struct SetupGallery: View {
    @State private var good = false

    var body: some View {
        ZStack {
            CDSetupBackground()
            VStack(spacing: 28) {
                HStack(alignment: .top, spacing: 40) {
                    CDStepIconView(.app)
                    CDStepIconView(.symbol("bell.badge"))
                    CDStepIconView(.success)
                }
                CDStepHeader(icon: .symbol("lock.shield"), title: "Allow the helper",
                             text: "ClamDown needs a small helper to keep your Mac awake with the lid closed. "
                                 + "macOS asks once, and you can remove it any time.")
                CDStatusCard {
                    CDStatusLine(symbol: good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                 tint: good ? CDColor.success : CDColor.warning,
                                 title: good ? "Helper allowed" : "Helper not allowed yet",
                                 detail: good ? "Nothing more to do." : nil) {
                        Button(good ? "Undo" : "Allow") { good.toggle() }.cdButtonStyle(.secondary)
                    }
                    Divider()
                    CDStatusLine(symbol: "xmark.octagon.fill", tint: CDColor.danger, title: "Could not register the helper",
                                 detail: "macOS answered: the operation could not be completed. Open System Settings, "
                                     + "choose Login Items, and allow ClamDown there, then press Try Again.",
                                 detailTone: .danger) {
                        Button("Try Again") {}.cdButtonStyle(.primary)
                    }
                    Divider()
                    CDStatusLine(symbol: "bell.fill", tint: .secondary, title: "A line with no action")
                }
                .frame(maxWidth: 470)
                HStack(spacing: 16) {
                    CDStepDots(count: 5, current: 2)
                    CDStepDots(count: 2, current: 0)
                    Button("Back") {}.cdButtonStyle(.secondary)
                    Button("Continue") {}.cdButtonStyle(.primary)
                }
                .controlSize(.large)
            }
            .padding(.vertical, 36)
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
#endif
