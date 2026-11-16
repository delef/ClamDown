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
            CDSection(String(localized: "Startup")) {
                LaunchAtLoginRow(controller: controller)
                CDSwitchRow(String(localized: "Show Dock Icon"),
                            detail: String(localized: "Adds ClamDown to the Dock. Clicking it opens these settings."),
                            isOn: controller.binding(\.showDockIcon))
            }
            CDSection(String(localized: "Notifications")) {
                CDSwitchRow(String(localized: "Notify When Switched Off"),
                            detail: String(localized: """
                                Tells you when ClamDown switches itself off, for example at low battery. The menu \
                                always shows the reason.
                                """),
                            isOn: controller.binding(\.notificationsEnabled))
                notificationHint
            }
            CDSection(String(localized: "Settings")) {
                CDRow(String(localized: "Reset All Settings"),
                      detail: String(localized: """
                          Restores every setting to its default. Launch at Login stays as it is.
                          """)) {
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
            notificationHintLine(button: String(localized: "Allow")) {
                Task { permission = await notifications.requestPermission() }
            }
        case .openSettings:
            notificationHintLine(button: String(localized: "Open Notification Settings")) {
                SystemSettings.openNotifications()
            }
        }
    }

    private func notificationHintLine(button: String, action: @escaping () -> Void) -> some View {
        HStack {
            CDNote(String(localized: "macOS is not showing ClamDown's notifications yet."), tone: .warning)
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
            CDSection(String(localized: "Keep Awake")) {
                CDRow(String(localized: "Switch Off After"),
                      detail: String(localized: """
                          Turns the mode off by itself after this time. Turn On For\u{2026} in the menu \
                          overrides it once.
                          """)) {
                    Picker("Switch Off After", selection: controller.binding(\.autoOffTimer)) {
                        ForEach(AutoOffTimer.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 130, alignment: .trailing)
                }
                CDSwitchRow(String(localized: "Switch Off When Unplugged"),
                            detail: String(localized: """
                                Lets the Mac sleep as soon as the power adapter is disconnected.
                                """),
                            isOn: controller.binding(\.turnOffWhenUnplugged))
            }
            CDSection(String(localized: "Security")) {
                CDSwitchRow(String(localized: "Lock Screen When Closed"),
                            detail: String(localized: """
                                Without this, a Mac kept awake with the lid closed opens without a password.
                                """),
                            isOn: controller.binding(\.lockScreenWhenLidClosed))
            }
            CDSection(String(localized: "Power")) {
                CDSwitchRow(String(localized: "Low Power Mode on Battery"),
                            detail: String(localized: """
                                Switches on Low Power Mode on battery while ClamDown is on, and puts it back \
                                afterwards.
                                """),
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
            CDSection(String(localized: "Battery")) {
                CDSwitchRow(String(localized: "Switch Off at Low Battery"),
                            detail: String(localized: """
                                Lets the Mac sleep at this level, so it does not run flat in a bag.
                                """),
                            isOn: controller.binding(\.batteryCutoffEnabled))
                if controller.settings.batteryCutoffEnabled {
                    SettingSlider(String(localized: "Level"), value: controller.binding(\.batteryCutoffPercent),
                                  range: AppSettings.batteryCutoffRange, unit: "%")
                }
            }
            CDSection(String(localized: "Heat")) {
                CDRow(String(localized: "Switch Off When Hot"),
                      detail: String(localized: """
                          Lets the Mac sleep when macOS reports this thermal level. Now: \
                          \(ThermalLevel(ProcessInfo.processInfo.thermalState).localizedName).
                          """)) {
                    Picker("Switch Off When Hot", selection: controller.binding(\.thermalCutoff)) {
                        ForEach(ThermalCutoff.allCases, id: \.self) { Text(Self.label(for: $0)).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 150, alignment: .trailing)
                }
                CDSwitchRow(String(localized: "Switch Off When the Battery Is Hot"),
                            detail: String(localized: """
                                Lets the Mac sleep when the battery stays this hot, as it can in a bag. Now: \
                                \(batteryNow).
                                """),
                            isOn: controller.binding(\.batteryHeatCutoffEnabled))
                if controller.settings.batteryHeatCutoffEnabled {
                    SettingSlider(String(localized: "Limit"), value: controller.binding(\.batteryHeatLimit),
                                  range: AppSettings.batteryHeatLimitRange, unit: " \u{00B0}C")
                    CDRow(String(localized: "For At Least")) {
                        Picker("For At Least", selection: controller.binding(\.batteryHeatHold)) {
                            ForEach(BatteryHeatHold.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 150, alignment: .trailing)
                    }
                }
            }
            CDSection(String(localized: "After Switching Off")) {
                CDSwitchRow(String(localized: "Put the Mac to Sleep"),
                            detail: String(localized: """
                                When low battery or heat switches ClamDown off and nobody is at the Mac, it goes to \
                                sleep at once.
                                """),
                            isOn: controller.binding(\.sleepAfterProtection))
            }
        }
    }

    private var batteryNow: String {
        controller.batteryTemperature().map { String(localized: "\(Int($0.rounded())) \u{00B0}C") } ?? String(localized: "unknown")
    }

    private static func label(for cutoff: ThermalCutoff) -> String {
        switch cutoff {
        case .fair: String(localized: "Fair (earliest)")
        case .serious: String(localized: "Serious")
        case .critical: String(localized: "Critical (latest)")
        case .never: String(localized: "Never")
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
            CDSection(String(localized: "Fans")) {
                if let reason = unsupportedReason {
                    // The stored choice stays as it is; on this Mac it cannot do anything.
                    CDSwitchRow(String(localized: "Fan Control"), detail: reason, isOn: .constant(false))
                        .disabled(true)
                    CDNote(Self.offNote)
                } else {
                    CDSwitchRow(String(localized: "Fan Control"),
                                detail: String(localized: """
                                    Off: macOS keeps the fans. ClamDown hands them back when it switches off, quits or \
                                    crashes.
                                    """),
                                isOn: controller.binding(\.fanControlEnabled))
                    if controller.settings.fanControlEnabled {
                        CDRow(String(localized: "Curve")) { modePicker }
                        curve
                        caseRule
                        if let note = controlNote {
                            CDNote(note, tone: .warning)
                        }
                        CDSwitchRow(String(localized: "Only With Lid Closed"),
                                    detail: String(localized: """
                                        Leaves the fans to macOS while the lid is open, so they stay quiet while you work.
                                        """),
                                    isOn: controller.binding(\.fansOnlyWhenLidClosed))
                    } else {
                        CDNote(Self.offNote)
                    }
                }
            }
            CDSection(String(localized: "Now")) {
                CDValueRow(String(localized: "Hottest"), value: hottestText)
                ForEach(groupsShown, id: \.self) { group in
                    CDValueRow(group.localizedTitle, value: Self.temperatureText(status?.groupTemperatures[group]))
                }
                if groupsShown.isEmpty, let average = status?.cpuTemperature {
                    // Without the groups the helper follows the average CPU temperature, so that is what is shown.
                    CDValueRow(String(localized: "CPU Temperature"), value: Self.temperatureText(average))
                }
                ForEach(Array((status?.fans ?? []).enumerated()), id: \.offset) { index, fan in
                    CDValueRow(String(localized: "Fan \(index + 1)"),
                               value: String(localized: "\(Int(fan.rpm.rounded()).formatted()) rpm"))
                }
                CDValueRow(String(localized: "Controlled By"),
                           value: status?.isControlling == true
                               ? String(localized: "ClamDown") : String(localized: "macOS"))
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

    private static let offNote = String(localized: "macOS controls the fans. ClamDown does not touch them.")

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
                          nowTemperature: status?.hottestTemperature ?? status?.cpuTemperature,
                          firstFan: status?.fans.first) { index, point in
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
                ? String(localized: """
                    Fans stay at their lowest speed up to the first point and reach full speed at the \
                    second, following the hottest of the CPU, GPU, battery, SSD, Wi-Fi and airflow \
                    sensors.
                    """)
                : String(localized: """
                    Five points, each at or above the one before it, on the hottest sensor; the fans \
                    never run under the safety floor.
                    """))
        }
    }

    /// The case rule: its own two temperatures on the airflow sensors, on top of the curve.
    @ViewBuilder private var caseRule: some View {
        CDRow(String(localized: "Case"), detail: String(localized: """
            The case can feel hot while the chips are only warm. The fans also speed up with the \
            airflow sensors: from the first value, full speed at the second. Now: \
            \(Self.temperatureText(status?.groupTemperatures[.airflow])).
            """))
        SettingSlider(String(localized: "Speeds Up From"), value: controller.binding(\.caseStartTemperature),
                      range: CaseRamp.startRange, unit: " \u{00B0}C")
        SettingSlider(String(localized: "Full Speed At"), value: controller.binding(\.caseFullSpeedTemperature),
                      range: (CaseRamp.startRange.lowerBound + CaseRamp.minimumSpan)...CaseRamp.fullSpeedMaximum,
                      unit: " \u{00B0}C")
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
                    .accessibilityLabel(String(localized: """
                        Point \(index + 1): \(points[index].temperature) degrees, \(points[index].speed) \
                        percent
                        """))
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
        case .hotCore: String(localized: "Full speed: a CPU core is at its limit.")
        case .hotBattery: String(localized: "Full speed: the battery is hot.")
        case .system: String(localized: "Full speed: macOS reports the Mac as hot.")
        case nil: nil
        }
    }

    /// A fault on the way: retrying shows only here; stopped also shows in the menu, with the same words.
    private var controlNote: String? {
        guard let status else { return nil }
        switch status.control {
        case .retrying:
            let paused = status.handBackFailed
                ? String(localized: """
                    Fan control paused. ClamDown takes the fans again in a moment; they run at full speed until then.
                    """)
                : String(localized: """
                    Fan control paused. ClamDown takes the fans again in a moment; macOS has them until then.
                    """)
            return FanAlert.sentence(from: status.problem).map { String.sentences(paused, $0) } ?? paused
        case .stopped:
            return FanAlert.line(reason: status.problem, fansAtFullSpeed: status.handBackFailed)
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
        return statusLoaded ? String(localized: "Cannot read the temperature sensors.") : nil
    }

    /// "52 °C (Battery)": what the curve follows now.
    private var hottestText: String {
        guard let celsius = status?.hottestTemperature else { return "\u{2014}" }
        let temperature = Self.temperatureText(celsius)
        guard let group = status?.hottestGroup else { return temperature }
        return String(localized: "\(temperature) (\(group.localizedTitle))", comment: "A temperature and the sensor group it comes from.")
    }

    /// The groups this Mac reports a value for, in their usual order.
    private var groupsShown: [SensorGroup] {
        SensorGroup.allCases.filter { status?.groupTemperatures[$0] != nil }
    }

    private static func temperatureText(_ temperature: Double?) -> String {
        temperature.map { String(localized: "\(Int($0.rounded())) \u{00B0}C") } ?? "\u{2014}"
    }
}

// MARK: - Appearance

struct AppearancePage: View {
    @ObservedObject var controller: ClamDownController

    private let pane = SettingsPane.appearance

    var body: some View {
        CDSettingsPage(title: pane.title, subtitle: pane.subtitle, symbol: pane.symbol) {
            CDSection(String(localized: "Menu Bar")) {
                CDRow(String(localized: "Icon Style"), detail: String(localized: "The icon fills in while ClamDown is on."))
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
            CDSection(String(localized: "Helper")) {
                CDValueRow(String(localized: "Status"), value: statusText, tone: statusTone)
                if let notice = controller.notice {
                    CDNote(notice)
                }
                CDRow(String(localized: "Reinstall Helper"),
                      detail: String(localized: """
                          Installs the helper from this version again. Use it when the helper is stuck.
                          """)) {
                    Button("Reinstall") { run { await controller.reinstallHelper() } }
                        .cdButtonStyle(.secondary)
                }
                CDRow(String(localized: "Approve in System Settings"),
                      detail: String(localized: """
                          Opens Login Items & Extensions, where macOS asks you to allow the helper.
                          """)) {
                    Button("Open\u{2026}") { controller.openHelperApproval() }
                        .cdButtonStyle(.secondary)
                }
                CDRow(String(localized: "Remove Helper"),
                      detail: String(localized: """
                          Puts back your original power settings and removes the helper. Turn On sets it up \
                          again.
                          """)) {
                    Button("Remove") { run { await controller.removeHelper() } }
                        .cdButtonStyle(.destructive)
                }
            }
            CDSection(String(localized: "Setup")) {
                CDRow(String(localized: "Setup Assistant"),
                      detail: String(localized: "Walks through the helper, notifications and startup again.")) {
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
        case .ready: String(localized: "Running")
        case .requiresApproval: String(localized: "Needs approval")
        case .notRegistered: String(localized: "Not installed")
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
