import SwiftUI
import ClamDownAppKit
import ClamDownShared

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
    @EnvironmentObject private var updater: Updater
    /// Assumed allowed until read, so the hint below does not flash while the page opens.
    @State private var permission: NotificationPermission = .allowed

    var body: some View {
        SettingsPage(title: "General") {
            SettingsSection(title: "Startup", icon: "power") {
                LaunchAtLoginRow(controller: controller)
                RowDivider()
                SettingRow(icon: "dock.rectangle", title: "Show Dock Icon",
                           help: "Adds ClamDown to the Dock. Clicking it opens these settings.") {
                    StatusToggle(isOn: controller.binding(\.showDockIcon))
                }
            }
            SettingsSection(title: "Notifications", icon: "bell") {
                SettingRow(icon: "bell.badge", title: "Notify When Switched Off",
                           help: "Shows a notification when ClamDown switches itself off, for example at low battery. The menu always shows the reason.") {
                    StatusToggle(isOn: controller.binding(\.notificationsEnabled))
                }
                notificationHint
            }
            SettingsSection(title: "Updates", icon: "arrow.down.circle") {
                SettingRow(icon: "clock.arrow.circlepath", title: "Check Automatically",
                           help: "Looks for a new version on GitHub once a day. The check downloads the list of releases and sends nothing about you or your Mac.") {
                    StatusToggle(isOn: $updater.checksAutomatically)
                }
                RowDivider()
                SettingRow(icon: "arrow.down.app", title: "Check for Updates",
                           help: "Looks for a new version now. You choose whether to install it.") {
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            }
            SettingsSection(title: "Settings", icon: "arrow.counterclockwise") {
                SettingRow(icon: "arrow.uturn.backward", title: "Reset All Settings",
                           help: "Restores every setting to its default. Launch at Login stays as it is.") {
                    Button("Reset") { Task { await controller.resetSettings() } }
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
        SettingDetail {
            HStack {
                Text("macOS is not showing ClamDown's notifications yet.").foregroundStyle(.orange)
                Spacer(minLength: 12)
                Button(button, action: action)
            }
        }
    }
}

// MARK: - Sleep

struct SleepPage: View {
    @ObservedObject var controller: ClamDownController

    var body: some View {
        SettingsPage(title: "Sleep") {
            SettingsSection(title: "Keep Awake", icon: "moon.zzz") {
                SettingRow(icon: "timer", title: "Switch Off After",
                           help: "Turns the mode off by itself after this time. \"Turn On For…\" in the menu overrides it for one session.") {
                    Picker("", selection: controller.binding(\.autoOffTimer)) {
                        ForEach(AutoOffTimer.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
                RowDivider()
                SettingRow(icon: "powerplug", title: "Switch Off When Unplugged",
                           help: "Lets the Mac sleep as soon as the power adapter is disconnected, and refuses to turn on without it.") {
                    StatusToggle(isOn: controller.binding(\.turnOffWhenUnplugged))
                }
            }
            SettingsSection(title: "Security", icon: "lock") {
                SettingRow(icon: "lock.laptopcomputer", title: "Lock Screen When Closed",
                           help: "Without this, a Mac kept awake with the lid closed opens without a password. ClamDown locks the screen the moment the lid closes while the mode is on.") {
                    StatusToggle(isOn: controller.binding(\.lockScreenWhenLidClosed))
                }
            }
            SettingsSection(title: "Power", icon: "bolt") {
                SettingRow(icon: "battery.50", title: "Low Power Mode on Battery",
                           help: "Switches on Low Power Mode while the Mac runs on battery with the mode on, and puts it back afterwards.") {
                    StatusToggle(isOn: controller.binding(\.autoLowPowerOnBattery))
                }
            }
        }
    }
}

// MARK: - Protection

struct ProtectionPage: View {
    @ObservedObject var controller: ClamDownController

    var body: some View {
        SettingsPage(title: "Protection") {
            SettingsSection(title: "Battery", icon: "battery.25") {
                SettingRow(icon: "battery.25", title: "Switch Off at Low Battery",
                           help: "Lets the Mac sleep when the battery falls to this level, so it does not run flat in a bag.") {
                    StatusToggle(isOn: controller.binding(\.batteryCutoffEnabled))
                }
                if controller.settings.batteryCutoffEnabled {
                    SettingDetail {
                        HStack {
                            Text("Level")
                            Slider(
                                value: Binding(
                                    get: { Double(controller.settings.batteryCutoffPercent) },
                                    set: { value in
                                        var updated = controller.settings
                                        updated.batteryCutoffPercent = Int(value.rounded())
                                        Task { await controller.updateSettings(updated) }
                                    }
                                ),
                                in: Double(AppSettings.batteryCutoffRange.lowerBound)...Double(AppSettings.batteryCutoffRange.upperBound),
                                step: 1
                            )
                            Text("\(controller.settings.batteryCutoffPercent)%")
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                }
            }
            SettingsSection(title: "Heat Protection", icon: "thermometer.medium") {
                SettingRow(icon: "thermometer.high", title: "Switch Off When Hot",
                           help: "Lets the Mac sleep when macOS reports this thermal level. A Mac in a closed bag cannot shed heat.") {
                    Picker("", selection: controller.binding(\.thermalCutoff)) {
                        ForEach(ThermalCutoff.allCases, id: \.self) { Text(Self.label(for: $0)).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
                SettingDetail {
                    Text("Now: \(ThermalLevel(ProcessInfo.processInfo.thermalState).name.capitalized)")
                }
            }
            SettingsSection(title: "After Switching Off", icon: "moon.zzz") {
                SettingRow(icon: "powersleep", title: "Put the Mac to Sleep",
                           help: "When low battery or heat switches ClamDown off with the lid closed, the Mac goes to sleep at once, even if an app is keeping it awake. With the lid open, or in front of an external display, nothing happens.") {
                    StatusToggle(isOn: controller.binding(\.sleepAfterProtection))
                }
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

    var body: some View {
        SettingsPage(title: "Cooling") {
            SettingsSection(title: "Fans", icon: "fan") {
                SettingRow(icon: "fan", title: "Fan Control",
                           help: "Applies only while ClamDown is on. ClamDown hands the fans back to macOS when it switches off, quits or crashes.") {
                    Picker("", selection: controller.binding(\.fanMode)) {
                        ForEach(FanMode.allCases, id: \.self) { Text(Self.label(for: $0)).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                }
                if controller.settings.fanMode == .curve {
                    SettingDetail {
                        VStack(alignment: .leading, spacing: 6) {
                            temperatureSlider("Speed up from", \.fanStartTemperature, range: FanPolicy.startRange)
                            temperatureSlider("Full speed at", \.fanFullSpeedTemperature, range: FanPolicy.fullSpeedRange)
                            Text("Fans stay at their lowest speed up to the first point and reach full speed at the second, following the average CPU temperature.")
                                .font(.caption)
                        }
                    }
                }
                RowDivider()
                SettingRow(icon: "laptopcomputer", title: "Only With Lid Closed",
                           help: "Leaves the fans to macOS while the lid is open, so they stay quiet while you work at the Mac.") {
                    StatusToggle(isOn: controller.binding(\.fansOnlyWhenLidClosed))
                }
            }
            SettingsSection(title: "Now", icon: "gauge.with.dots.needle.33percent") {
                SettingRow(icon: "cpu", title: "CPU Temperature") {
                    Text(status?.cpuTemperature.map { "\(Int($0.rounded())) °C" } ?? "—").monospacedDigit()
                }
                ForEach(Array((status?.fans ?? []).enumerated()), id: \.offset) { index, fan in
                    RowDivider()
                    SettingRow(icon: "fan", title: "Fan \(index + 1)") {
                        Text("\(Int(fan.rpm)) rpm").monospacedDigit()
                    }
                }
                RowDivider()
                SettingRow(icon: "hand.raised", title: "Controlled By") {
                    Text(status?.isControlling == true ? "ClamDown" : "macOS")
                }
                if let problem = statusProblem {
                    SettingDetail { Text(problem).foregroundStyle(.orange) }
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

    private var statusProblem: String? {
        if let problem = status?.problem { return problem }
        if statusLoaded, status == nil { return "Cannot read the temperature sensors." }
        return nil
    }

    private func temperatureSlider(_ title: String, _ keyPath: WritableKeyPath<AppSettings, Int>, range: ClosedRange<Int>) -> some View {
        HStack {
            Text(title).frame(width: 110, alignment: .leading)
            Slider(
                value: Binding(
                    get: { Double(controller.settings[keyPath: keyPath]) },
                    set: { value in
                        var updated = controller.settings
                        updated[keyPath: keyPath] = Int(value.rounded())
                        Task { await controller.updateSettings(updated) }
                    }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: 1
            )
            Text("\(controller.settings[keyPath: keyPath]) °C")
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
        }
    }

    private static func label(for mode: FanMode) -> String {
        switch mode {
        case .system: "macOS (no change)"
        case .curve: "Temperature Curve"
        case .fullSpeed: "Full Speed"
        }
    }
}

// MARK: - Appearance

struct AppearancePage: View {
    @ObservedObject var controller: ClamDownController

    var body: some View {
        SettingsPage(title: "Appearance") {
            SettingsSection(title: "Menu Bar", icon: "menubar.rectangle") {
                SettingRow(icon: "star", title: "Icon Style",
                           help: "The icon is filled while the mode is on.") {
                    HStack(spacing: 8) {
                        ForEach(MenuBarIconStyle.allCases, id: \.self) { style in
                            IconTile(style: style, isSelected: controller.settings.menuBarIcon == style) {
                                var updated = controller.settings
                                updated.menuBarIcon = style
                                Task { await controller.updateSettings(updated) }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct IconTile: View {
    let style: MenuBarIconStyle
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: style.offSymbol)
                    Image(systemName: style.onSymbol)
                }
                .font(.title3)
                Text(style.title).font(.caption)
            }
            .frame(width: 70, height: 52)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(style.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Helper

struct HelperPage: View {
    @ObservedObject var controller: ClamDownController
    let openSetup: () -> Void

    var body: some View {
        SettingsPage(title: "Helper") {
            SettingsSection(title: "Helper Application", icon: "gearshape.2") {
                SettingRow(icon: "circle.fill", title: "Status",
                           help: "ClamDown needs a small background helper with administrator rights to change the sleep setting and drive the fans. It does nothing else.") {
                    Text(statusText).foregroundStyle(statusColor)
                }
                if let notice = controller.notice {
                    SettingDetail { Text(notice) }
                }
                RowDivider()
                SettingRow(icon: "arrow.triangle.2.circlepath", title: "Reinstall Helper",
                           help: "Installs the helper from this build again. Use it when the helper is stuck.") {
                    Button("Reinstall") { run { await controller.reinstallHelper() } }
                }
                RowDivider()
                SettingRow(icon: "person.badge.key", title: "Approve in System Settings",
                           help: "Opens Login Items & Extensions, where macOS asks you to allow the helper.") {
                    Button("Open") { controller.openHelperApproval() }
                }
                RowDivider()
                SettingRow(icon: "trash", title: "Remove Helper",
                           help: "Removes the helper. Turn On sets it up again.") {
                    Button("Remove", role: .destructive) { run { await controller.removeHelper() } }
                }
            }
            SettingsSection(title: "Setup", icon: "sparkles") {
                SettingRow(icon: "list.bullet.clipboard", title: "Setup Assistant",
                           help: "Walks through the helper, notifications and startup again.") {
                    Button("Open") { openSetup() }
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

    private var statusColor: Color {
        switch controller.helperAvailability {
        case .ready: .green
        case .requiresApproval: .orange
        case .notRegistered, .unavailable: .red
        }
    }
}
