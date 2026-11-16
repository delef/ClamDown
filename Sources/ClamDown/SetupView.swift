import SwiftUI
import ClamDownAppKit
import ClamDownShared
import ClamDownUI

/// The setup assistant: one step per screen, with the steps and their rules coming from `SetupModel`.
struct SetupView: View {
    static let size = CGSize(width: 600, height: 540)

    @ObservedObject var model: SetupModel
    @ObservedObject var controller: ClamDownController
    let close: () -> Void
    /// Brings the window back in front of System Settings once the helper is allowed.
    let bringForward: () -> Void
    var loginItem: LoginItem = .system
    /// Debug previews only: an error already showing under the Launch at Login switch.
    var previewLoginError: String?
    /// Set after "Turn On Now" did not switch the mode on, so the reason is shown instead of closing silently.
    @State private var turnOnProblem: String?

    var body: some View {
        VStack(spacing: 0) {
            stepBody
                .cdStepTransition(id: model.step)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            footer
        }
        // The window sets the size (`SetupWindowController`); the view fills all of it, title bar included.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { CDSetupBackground().ignoresSafeArea() }
        .ignoresSafeArea()
        .task {
            await model.refreshNotifications()
            // macOS sends no notice when the helper is allowed in System Settings, so ask once a second.
            while !Task.isCancelled {
                if await model.refreshHelper() { bringForward() }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshNotifications() }
        }
        // The reason a Turn On failed belongs to the screen it was pressed on.
        .onChange(of: model.step) { _ in turnOnProblem = nil }
    }

    @ViewBuilder private var stepBody: some View {
        switch model.step {
        case .welcome: WelcomeStep()
        case .helper: HelperStep(model: model, controller: controller)
        case .notifications: NotificationsStep(model: model)
        case .startup: StartupStep(controller: controller, loginItem: loginItem, loginError: previewLoginError)
        case .done: DoneStep(controller: controller)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let turnOnProblem {
                CDNote(turnOnProblem, tone: .warning)
                    .lineLimit(3)
            } else if model.mode == .full {
                CDStepDots(count: model.steps.count, current: model.steps.firstIndex(of: model.step) ?? 0)
            }
            Spacer(minLength: 12)
            buttons
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 20)
        // The assistant is read at arm's length, once: its buttons are the large ones of a macOS setup window.
        .controlSize(.large)
    }

    /// The last screen, and the helper-only assistant, end the flow; every other screen moves through it.
    @ViewBuilder private var buttons: some View {
        if model.mode == .helperOnly || model.step == .done {
            if model.canGoBack {
                Button("Back") { model.back() }
                    .cdButtonStyle(.secondary)
            }
            if controller.state.isOn {
                Button("Done") { close() }
                    .cdButtonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Done") { close() }
                    .cdButtonStyle(.secondary)
                Button(controller.turnOnStep == nil ? String(localized: "Turn On Now") : String(localized: "Turning On…")) {
                    turnOnNow()
                }
                    .cdButtonStyle(.primary)
                    .keyboardShortcut(model.helperWorks ? .defaultAction : nil)
                    .disabled(!model.helperWorks || model.isTurningOn || controller.turnOnStep != nil)
            }
        } else {
            if model.canGoBack {
                Button("Back") { model.back() }
                    .cdButtonStyle(.secondary)
            }
            Button(continueTitle) { model.advance() }
                .cdButtonStyle(.primary)
                .keyboardShortcut(continueIsDefault ? .defaultAction : nil)
                .disabled(!model.canContinue)
        }
    }

    /// Return belongs to the step's own button while that is the thing to press: "Allow Notifications", not "Skip".
    private var continueIsDefault: Bool {
        model.canContinue && !(model.step == .notifications && model.notifications == .notAsked)
    }

    private var continueTitle: String {
        model.step == .notifications && model.notifications != .allowed
            ? String(localized: "Skip") : String(localized: "Continue")
    }

    private func turnOnNow() {
        turnOnProblem = nil
        Task {
            await model.turnOnNow()
            if controller.state.isOn {
                close()
            } else if case .failed(let message) = controller.state {
                turnOnProblem = message
            } else {
                turnOnProblem = controller.notice ?? String(localized: "ClamDown did not turn on.")
            }
        }
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    var body: some View {
        CDStepScreen(
            icon: .app,
            title: String(localized: "Welcome to ClamDown"),
            text: String(localized: """
                ClamDown keeps your MacBook working with the lid closed, so your agents keep going. \
                It locks the screen, drives the fans, and switches itself off before a low battery \
                or heat becomes a problem.
                """)
        )
    }
}

private struct HelperStep: View {
    @ObservedObject var model: SetupModel
    @ObservedObject var controller: ClamDownController

    var body: some View {
        CDStepScreen(
            icon: .symbol("key.fill"),
            title: String(localized: "Allow the helper"),
            text: String(localized: """
                ClamDown needs a small background helper with administrator rights. It changes the \
                sleep setting and drives the fans, and it does nothing else. macOS asks you to \
                allow it once.
                """)
        ) {
            CDStatusCard {
                CDStatusLine(symbol: status.symbol, busy: status.busy, tint: status.tint, title: status.title,
                             detail: status.detail, detailTone: status.detailTone) {
                    if turnOnFailure != nil, controller.turnOnStep == nil {
                        Button("Try Again") { Task { await controller.toggle() } }
                            .cdButtonStyle(.primary)
                            .controlSize(.large)
                            .keyboardShortcut(.defaultAction)
                    } else if model.helper == .ready, model.helperRun == .startFailed {
                        Button("Reinstall Helper") { Task { await controller.reinstallHelper() } }
                            .cdButtonStyle(.primary)
                            .controlSize(.large)
                            .keyboardShortcut(.defaultAction)
                    } else if let buttonTitle {
                        Button(buttonTitle) { Task { await model.allowHelper() } }
                            .cdButtonStyle(.primary)
                            .controlSize(.large)
                            .keyboardShortcut(.defaultAction)
                            .disabled(model.isPreparingHelper)
                    }
                }
            }
        }
    }

    /// Why the last Turn On failed while the helper itself is allowed. Approval has its own line below.
    private var turnOnFailure: String? {
        guard case .failed(let message) = controller.state, model.helper == .ready else { return nil }
        return message
    }

    private var status: StatusInfo {
        // A Turn On under way: the window may have opened for it, so it says what is going on.
        if let step = controller.turnOnStep, step != .starting {
            return .init(symbol: "circle.dashed", tint: .secondary, title: step.text, detail: step.detail, busy: true)
        }
        if controller.state.isOn {
            return .init(symbol: "checkmark.circle.fill", tint: CDColor.success, title: String(localized: "ClamDown is on"))
        }
        if let turnOnFailure {
            return .init(symbol: "exclamationmark.triangle.fill", tint: CDColor.danger,
                         title: String(localized: "ClamDown did not turn on"), detail: turnOnFailure, detailTone: .danger)
        }
        if let error = model.helperError {
            return .init(symbol: "exclamationmark.triangle.fill", tint: CDColor.danger, title: String(localized: "The helper is not set up"),
                         detail: error, detailTone: .danger)
        }
        switch model.helper {
        case .ready:
            // Allowed is not enough: macOS can allow a helper that launchd then never starts.
            switch model.helperRun {
            case .answers:
                return .init(symbol: "checkmark.circle.fill", tint: CDColor.success, title: String(localized: "Allowed"))
            case .startFailed:
                return .init(symbol: "exclamationmark.triangle.fill", tint: CDColor.danger,
                             title: String(localized: "macOS did not start the helper"),
                             detail: String(localized: "Reinstall it. If that does not help, restart the Mac."),
                             detailTone: .danger)
            case .silent, nil:
                return .init(symbol: "circle.dashed", tint: .secondary, title: String(localized: "Starting the helper…"),
                             busy: true)
            }
        case .requiresApproval:
            return .init(symbol: "clock.fill", tint: CDColor.warning, title: String(localized: "Waiting for you"),
                         detail: String(localized: """
                             Turn on ClamDown in System Settings > General > Login Items & Extensions.
                             """))
        case .notRegistered, .unavailable:
            return .init(symbol: "circle.dashed", tint: .secondary, title: String(localized: "Not set up yet"))
        }
    }

    private var buttonTitle: String? {
        if controller.turnOnStep != nil || controller.state.isOn { return nil }
        if model.helperError != nil { return String(localized: "Try Again") }
        switch model.helper {
        case .ready: return nil
        case .requiresApproval: return String(localized: "Open Login Items")
        case .notRegistered, .unavailable: return String(localized: "Allow…")
        }
    }
}

private struct NotificationsStep: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        CDStepScreen(
            icon: .symbol("bell.badge.fill"),
            title: String(localized: "Know when ClamDown switches off"),
            text: String(localized: """
                With the lid closed you cannot see the menu. A notification tells you when ClamDown \
                switched itself off, for example at low battery or when the Mac got hot.
                """)
        ) {
            CDStatusCard {
                CDStatusLine(symbol: status.symbol, tint: status.tint, title: status.title,
                             detail: status.detail, detailTone: status.detailTone) {
                    switch model.notifications {
                    case .notAsked:
                        Button("Allow Notifications") { Task { await model.allowNotifications() } }
                            .cdButtonStyle(.primary)
                            .controlSize(.large)
                            .keyboardShortcut(.defaultAction)
                            .disabled(model.isRequestingNotifications)
                    case .denied:
                        Button("Open Notification Settings") {
                            model.openedNotificationSettings()
                            SystemSettings.openNotifications()
                        }
                        .cdButtonStyle(.secondary)
                        .controlSize(.large)
                    case .allowed:
                        EmptyView()
                    }
                }
            }
        }
    }

    private var status: StatusInfo {
        switch model.notifications {
        case .notAsked:
            .init(symbol: "bell", tint: .secondary, title: String(localized: "Not allowed yet"))
        case .allowed:
            .init(symbol: "checkmark.circle.fill", tint: CDColor.success, title: String(localized: "Allowed"))
        case .denied:
            .init(symbol: "bell.slash.fill", tint: CDColor.warning, title: String(localized: "Switched off"),
                  detail: String(localized: "Notifications for ClamDown are off in System Settings."))
        }
    }
}

private struct StartupStep: View {
    @ObservedObject var controller: ClamDownController
    let loginItem: LoginItem
    var loginError: String?
    @State private var hasFans = false

    var body: some View {
        CDStepScreen(
            icon: .symbol("power"),
            title: String(localized: "Start with your Mac"),
            text: String(localized: """
                ClamDown can open in the menu bar when you log in, so it is ready when you need it.
                """)
        ) {
            VStack(alignment: .leading, spacing: 10) {
                CDStatusCard {
                    // One padded block: the switch row and its error note keep their own gap.
                    VStack(alignment: .leading, spacing: 8) {
                        LaunchAtLoginRow(controller: controller, loginItem: loginItem, initialError: loginError)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Label(protection.isEmpty ? String(localized: "No protection is switched on")
                        : String(localized: "Protection is already on"),
                          systemImage: "shield.lefthalf.filled")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                    if !protection.isEmpty {
                        CDStatusCard {
                            ForEach(Array(protection.enumerated()), id: \.offset) { index, item in
                                if index > 0 { Divider().padding(.horizontal, CDMetric.cardInset) }
                                ProtectionRow(icon: item.icon, text: item.text)
                            }
                        }
                    }
                    Text("You can change all of this in Settings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
            }
        }
        .task {
            hasFans = !((await controller.coolingStatus())?.fans.isEmpty ?? true)
        }
    }

    /// Built from the current settings, so the list never claims protection that is switched off.
    private var protection: [(icon: String, text: String)] {
        let settings = controller.settings
        var items: [(icon: String, text: String)] = []
        if settings.lockScreenWhenLidClosed {
            items.append(("lock.laptopcomputer", String(localized: "Locks the screen when the lid closes")))
        }
        if settings.batteryCutoffEnabled {
            items.append(("battery.25", String(localized: "Switches off at \(settings.batteryCutoffPercent)% battery")))
        }
        if settings.thermalCutoff != .never {
            items.append(("thermometer.high", String(localized: "Switches off when the Mac gets hot")))
        }
        if hasFans, settings.fanControlEnabled {
            items.append(("fan", String(localized: "Drives the fans from the hottest sensor")))
        }
        return items
    }
}

private struct DoneStep: View {
    @ObservedObject var controller: ClamDownController

    var body: some View {
        CDStepScreen(
            icon: .success,
            title: String(localized: "You're set"),
            text: String(localized: "ClamDown lives in the menu bar. Look for this icon:")
        ) {
            VStack(spacing: 18) {
                CDMenuBarStrip(clock: Date.now.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())) {
                    MenuBarIconGlyph(symbol: controller.settings.menuBarIcon.offSymbol)
                }
                Text("Turn it on before you close the lid.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Parts

/// What a status line says: a symbol, a short title and an optional sentence under it.
private struct StatusInfo {
    let symbol: String
    let tint: Color
    let title: String
    var detail: String?
    var detailTone: CDTone = .secondary
    var busy = false
}

private struct ProtectionRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            Text(text)
            Spacer(minLength: 12)
            Image(systemName: "checkmark")
                .font(.callout.weight(.semibold))
                .foregroundStyle(CDColor.success)
        }
        // The row height of a settings card: a list read at arm's length must not be cramped.
        .padding(.horizontal, CDMetric.cardInset)
        .padding(.vertical, CDMetric.cardRowPadding)
    }
}
