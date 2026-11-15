import SwiftUI
import ClamDownAppKit
import ClamDownSensors
import ClamDownShared
import ClamDownUI

/// SwiftUI has its own `Settings` scene type, so name ours explicitly.
typealias AppSettings = ClamDownAppKit.Settings

extension ClamDownController {
    /// Edits one setting and sends the whole settings value back to the controller.
    func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { newValue in
                var updated = self.settings
                updated[keyPath: keyPath] = newValue
                Task { await self.updateSettings(updated) }
            }
        )
    }
}

// MARK: - General

struct GeneralPage: View {
    @ObservedObject var controller: ClamDownController
    let notifications: NotificationAuthorizing
    /// Assumed allowed until read, so the hint below does not flash while the page opens.
    @State private var permission: NotificationPermission = .allowed

    private let pane = SettingsPane.general

    var body: some View {
        CDSettingsPage(title: pane.title, subtitle: pane.subtitle, symbol: pane.symbol) {
            CDSection("Startup") {
                LaunchAtLoginRow(controller: controller)
                CDSwitchRow("Show Dock Icon",
                            detail: "Adds ClamDown to the Dock. Clicking it opens these settings.",
                            isOn: controller.binding(\.showDockIcon))
            }
            CDSection("Notifications") {
                CDSwitchRow("Notify When Switched Off",
                            detail: "Tells you when ClamDown switches itself off, for example at low battery. "
                                + "The menu always shows the reason.",
                            isOn: controller.binding(\.notificationsEnabled))
                notificationHint
            }
            CDSection("Settings") {
                CDRow("Reset All Settings",
                      detail: "Restores every setting to its default. Launch at Login stays as it is.") {
                    Button("Reset") { Task { await controller.resetSettings() } }
                        .cdButtonStyle(.secondary)
                }
            }
        }
        .task { permission = await notifications.permission() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { permission = await notifications.permission() }
        }
    }

    /// Says so when the setting is on but macOS shows nothing, and offers the way out.
    @ViewBuilder private var notificationHint: some View {
        switch permission.hint(settingOn: controller.settings.notificationsEnabled) {
        case .nothing:
            EmptyView()
        case .allow:
            notificationHintLine(button: "Allow") {
                Task { permission = await notifications.requestPermission() }
            }
        case .openSettings:
            notificationHintLine(button: "Open Notification Settings") {
                SystemSettings.openNotifications()
            }
        }
    }

    private func notificationHintLine(button: String, action: @escaping () -> Void) -> some View {
        HStack {
            CDNote("macOS is not showing ClamDown's notifications yet.", tone: .warning)
            Button(button, action: action)
                .cdButtonStyle(.secondary)
        }
    }
}

// MARK: - Sleep

struct SleepPage: View {
    @ObservedObject var controller: ClamDownController

    private let pane = SettingsPane.sleep

    var body: some View {
        CDSettingsPage(title: pane.title, subtitle: pane.subtitle, symbol: pane.symbol) {
            CDSection("Keep Awake") {
                CDRow("Switch Off After",
                      detail: "Turns the mode off by itself after this time. Turn On For\u{2026} in the menu overrides it once.") {
                    Picker("Switch Off After", selection: controller.binding(\.autoOffTimer)) {
                        ForEach(AutoOffTimer.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 130, alignment: .trailing)
                }
                CDSwitchRow("Switch Off When Unplugged",
                            detail: "Lets the Mac sleep as soon as the power adapter is disconnected.",
                            isOn: controller.binding(\.turnOffWhenUnplugged))
            }
            CDSection("Security") {
                CDSwitchRow("Lock Screen When Closed",
                            detail: "Without this, a Mac kept awake with the lid closed opens without a password.",
                            isOn: controller.binding(\.lockScreenWhenLidClosed))
            }
            CDSection("Power") {
                CDSwitchRow("Low Power Mode on Battery",
                            detail: "Switches on Low Power Mode on battery while ClamDown is on, and puts it back afterwards.",
                            isOn: controller.binding(\.autoLowPowerOnBattery))
            }
        }
    }
}

// MARK: - Protection

struct ProtectionPage: View {
    @ObservedObject var controller: ClamDownController

    private let pane = SettingsPane.protection

    var body: some View {
        CDSettingsPage(title: pane.title, subtitle: pane.subtitle, symbol: pane.symbol) {
            CDSection("Battery") {
                CDSwitchRow("Switch Off at Low Battery",
                            detail: "Lets the Mac sleep at this level, so it does not run flat in a bag.",
                            isOn: controller.binding(\.batteryCutoffEnabled))
                if controller.settings.batteryCutoffEnabled {
                    SettingSlider("Level", value: controller.binding(\.batteryCutoffPercent),
                                  range: AppSettings.batteryCutoffRange, unit: "%")
                }
            }
            CDSection("Heat") {
                CDRow("Switch Off When Hot",
                      detail: "Lets the Mac sleep when macOS reports this thermal level. "
                          + "Now: \(ThermalLevel(ProcessInfo.processInfo.thermalState).name.capitalized).") {
                    Picker("Switch Off When Hot", selection: controller.binding(\.thermalCutoff)) {
                        ForEach(ThermalCutoff.allCases, id: \.self) { Text(Self.label(for: $0)).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 150, alignment: .trailing)
                }
            }
            CDSection("After Switching Off") {
                CDSwitchRow("Put the Mac to Sleep",
                            detail: "When low battery or heat switches ClamDown off and nobody is at the Mac, "
                                + "it goes to sleep at once.",
                            isOn: controller.binding(\.sleepAfterProtection))
            }
        }
    }

    private static func label(for cutoff: ThermalCutoff) -> String {
        switch cutoff {
        case .fair: "Fair (earliest)"
        case .serious: "Serious"
        case .critical: "Critical (latest)"
        case .never: "Never"
        }
    }
}

// MARK: - Cooling

struct CoolingPage: View {
    @ObservedObject var controller: ClamDownController
    @State private var status: CoolingStatus?
    @State private var statusLoaded = false

    private let pane = SettingsPane.cooling

    var body: some View {
        CDSettingsPage(title: pane.title, subtitle: pane.subtitle, symbol: pane.symbol) {
            CDSection("Fans") {
                if let reason = unsupportedReason {
                    // The stored choice stays as it is; on this Mac it cannot do anything.
                    CDSwitchRow("Fan Control", detail: reason, isOn: .constant(false))
                        .disabled(true)
                    CDNote(Self.offNote)
                } else {
                    CDSwitchRow("Fan Control",
                                detail: "Off: macOS keeps the fans. ClamDown hands them back when it switches off, "
                                    + "quits or crashes.",
                                isOn: controller.binding(\.fanControlEnabled))
                    if controller.settings.fanControlEnabled {
                        CDRow("Curve") { modePicker }
                        curve
                        if let note = controlNote {
                            CDNote(note, tone: .warning)
                        }
                        CDSwitchRow("Only With Lid Closed",
                                    detail: "Leaves the fans to macOS while the lid is open, so they stay quiet while you work.",
                                    isOn: controller.binding(\.fansOnlyWhenLidClosed))
                    } else {
                        CDNote(Self.offNote)
                    }
                }
            }
            CDSection("Now") {
                CDValueRow("CPU Temperature", value: Self.temperatureText(status?.cpuTemperature))
                CDValueRow("Hottest Core", value: Self.temperatureText(status?.hottestCPUTemperature))
                ForEach(Array((status?.fans ?? []).enumerated()), id: \.offset) { index, fan in
                    CDValueRow("Fan \(index + 1)", value: "\(Int(fan.rpm.rounded()).formatted()) rpm")
                }
                CDValueRow("Controlled By", value: status?.isControlling == true ? "ClamDown" : "macOS")
                if let problem = statusProblem {
                    CDNote(problem, tone: .warning)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                status = await controller.coolingStatus()
                statusLoaded = true
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private static let offNote = "macOS controls the fans. ClamDown does not touch them."

    private var modePicker: some View {
        Picker("Curve", selection: Binding(
            get: { controller.settings.fanCurveMode },
            set: { mode in
                var updated = controller.settings
                if mode == .advanced {
                    updated = FanCurveEditor.chooseAdvanced(updated)
                } else {
                    updated.fanCurveMode = .standard
                }
                save(updated)
            })) {
            Text("Standard").tag(FanCurveMode.standard)
            Text("Advanced").tag(FanCurveMode.advanced)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    /// The chart, the override in force, the values with Reset, and what the mode does.
    private var curve: some View {
        let settings = controller.settings
        let points = settings.fanCurvePoints
        return VStack(alignment: .leading, spacing: 10) {
            FanCurveChart(points: points, mode: settings.fanCurveMode,
                          nowTemperature: status?.cpuTemperature, firstFan: status?.fans.first) { index, point in
                save(FanCurveEditor.moved(controller.settings, dragging: index, to: point))
            }
            if let line = overrideLine {
                CDNote(line, tone: .warning)
            }
            HStack(alignment: .center, spacing: CDMetric.rowSpacing) {
                values(points, mode: settings.fanCurveMode)
                Spacer(minLength: CDMetric.rowSpacing)
                Button("Reset") { save(FanCurveEditor.reset(controller.settings)) }
                    .cdButtonStyle(.secondary)
                    .help("Puts this mode's curve back to its defaults.")
            }
            CDNote(settings.fanCurveMode == .standard
                ? "Fans stay at their lowest speed up to the first point and reach full speed at the second, "
                    + "following the average CPU temperature."
                : "Five points, each at or above the one before it, on the average CPU temperature; the fans never "
                    + "run under the safety floor.")
        }
    }

    @ViewBuilder private func values(_ points: [FanPoint], mode: FanCurveMode) -> some View {
        switch mode {
        case .standard where points.count == 2:
            HStack(spacing: 16) {
                Text("Speeds up from ") + Text("\(points[0].temperature) \u{00B0}C").fontWeight(.semibold)
                Text("Full speed at ") + Text("\(points[1].temperature) \u{00B0}C").fontWeight(.semibold)
            }
            .monospacedDigit()
        default:
            HStack(spacing: 14) {
                ForEach(points.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(points[index].temperature) \u{00B0}C").fontWeight(.semibold)
                        Text("\(points[index].speed) %").font(.callout).foregroundStyle(.secondary)
                    }
                    .monospacedDigit()
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Point \(index + 1): \(points[index].temperature) degrees, "
                        + "\(points[index].speed) percent")
                }
            }
        }
    }

    private func save(_ settings: AppSettings) {
        Task { await controller.updateSettings(settings) }
    }

    /// Why the fans cannot be driven on this Mac at all, as the helper reports it.
    private var unsupportedReason: String? {
        guard let problem = status?.problem, problem == FanHardwareError.unsupported.description else { return nil }
        return problem
    }

    private var overrideLine: String? {
        switch status?.override {
        case .hotCore: "Full speed: a CPU core is at its limit."
        case .hotBattery: "Full speed: the battery is hot."
        case .system: "Full speed: macOS reports the Mac as hot."
        case nil: nil
        }
    }

    /// A fault on the way: retrying shows only here; stopped also shows in the menu, with the same words.
    private var controlNote: String? {
        guard let status else { return nil }
        switch status.control {
        case .retrying:
            let clause = FanAlert.clause(from: status.problem).map { ": \($0)" } ?? ""
            return "Fan control paused\(clause). ClamDown takes the fans again in a moment; macOS has them until then."
        case .stopped:
            return FanAlert.line(reason: status.problem)
        case .idle, .controlling:
            return nil
        }
    }

    private var statusProblem: String? {
        if let status {
            // These have their own lines in the Fans section.
            if status.control == .retrying || status.control == .stopped || unsupportedReason != nil { return nil }
            return status.problem
        }
        return statusLoaded ? "Cannot read the temperature sensors." : nil
    }

    private static func temperatureText(_ temperature: Double?) -> String {
        temperature.map { "\(Int($0.rounded())) \u{00B0}C" } ?? "\u{2014}"
    }
}

// MARK: - Appearance

struct AppearancePage: View {
    @ObservedObject var controller: ClamDownController

    private let pane = SettingsPane.appearance

    var body: some View {
        CDSettingsPage(title: pane.title, subtitle: pane.subtitle, symbol: pane.symbol) {
            CDSection("Menu Bar") {
                CDRow("Icon Style", detail: "The icon fills in while ClamDown is on.")
                HStack(spacing: 8) {
                    ForEach(MenuBarIconStyle.allCases, id: \.self) { style in
                        CDChoiceTile(style.title, isSelected: controller.settings.menuBarIcon == style) {
                            var updated = controller.settings
                            updated.menuBarIcon = style
                            Task { await controller.updateSettings(updated) }
                        } content: {
                            HStack(spacing: 6) {
                                MenuBarIconGlyph(symbol: style.offSymbol)
                                MenuBarIconGlyph(symbol: style.onSymbol)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Helper

struct HelperPage: View {
    @ObservedObject var controller: ClamDownController
    let openSetup: () -> Void

    private let pane = SettingsPane.helper

    var body: some View {
        CDSettingsPage(title: pane.title, subtitle: pane.subtitle, symbol: pane.symbol) {
            CDSection("Helper") {
                CDValueRow("Status", value: statusText, tone: statusTone)
                if let notice = controller.notice {
                    CDNote(notice)
                }
                CDRow("Reinstall Helper",
                      detail: "Installs the helper from this version again. Use it when the helper is stuck.") {
                    Button("Reinstall") { run { await controller.reinstallHelper() } }
                        .cdButtonStyle(.secondary)
                }
                CDRow("Approve in System Settings",
                      detail: "Opens Login Items & Extensions, where macOS asks you to allow the helper.") {
                    Button("Open\u{2026}") { controller.openHelperApproval() }
                        .cdButtonStyle(.secondary)
                }
                CDRow("Remove Helper", detail: "Removes the helper. Turn On sets it up again.") {
                    Button("Remove") { run { await controller.removeHelper() } }
                        .cdButtonStyle(.destructive)
                }
            }
            CDSection("Setup") {
                CDRow("Setup Assistant", detail: "Walks through the helper, notifications and startup again.") {
                    Button("Open\u{2026}") { openSetup() }
                        .cdButtonStyle(.secondary)
                }
            }
        }
        .onAppear { controller.refreshHelperAvailability() }
    }

    private func run(_ work: @escaping () async -> Void) {
        Task { await work() }
    }

    /// The controller's published state, so this page and the setup assistant never disagree.
    private var statusText: String {
        switch controller.helperAvailability {
        case .ready: "Running"
        case .requiresApproval: "Needs approval"
        case .notRegistered: "Not installed"
        case .unavailable(let message): message
        }
    }

    private var statusTone: CDTone {
        switch controller.helperAvailability {
        case .ready: .success
        case .requiresApproval: .warning
        case .notRegistered, .unavailable: .danger
        }
    }
}

// MARK: - Shared

/// A titled slider with its value at the end, as one row of a section.
private struct SettingSlider: View {
    private let title: String
    @Binding private var value: Int
    private let range: ClosedRange<Int>
    private let unit: String

    init(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, unit: String) {
        self.title = title
        self._value = value
        self.range = range
        self.unit = unit
    }

    var body: some View {
        HStack(spacing: CDMetric.rowSpacing) {
            Text(title).frame(width: 110, alignment: .leading)
            Slider(value: Binding(get: { Double(value) }, set: { value = Int($0.rounded()) }),
                   in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
                .accessibilityLabel(title)
            Text("\(value)\(unit)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }
}
