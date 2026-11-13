import SwiftUI
import ClamDownAppKit
import ClamDownShared

/// The setup assistant: one step per screen, with the steps and their rules coming from `SetupModel`.
struct SetupView: View {
    static let size = CGSize(width: 560, height: 520)

    @ObservedObject var model: SetupModel
    @ObservedObject var controller: ClamDownController
    let close: () -> Void
    /// Brings the window back in front of System Settings once the helper is allowed.
    let bringForward: () -> Void
    var loginItem: LoginItem = .system
    /// Set after "Turn On Now" did not switch the mode on, so the reason is shown instead of closing silently.
    @State private var turnOnProblem: String?

    var body: some View {
        VStack(spacing: 0) {
            stepBody
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await model.refreshNotifications()
            // macOS sends no notice when the helper is allowed in System Settings, so ask once a second.
            while !Task.isCancelled {
                if model.refreshHelper() { bringForward() }
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
        case .helper: HelperStep(model: model)
        case .notifications: NotificationsStep(model: model)
        case .startup: StartupStep(controller: controller, loginItem: loginItem)
        case .done: DoneStep(controller: controller)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let turnOnProblem {
                Text(turnOnProblem)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.mode == .full {
                StepDots(steps: model.steps, current: model.step)
            }
            Spacer(minLength: 12)
            buttons
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
    }

    /// The last screen, and the helper-only assistant, end the flow; every other screen moves through it.
    @ViewBuilder private var buttons: some View {
        if model.mode == .helperOnly || model.step == .done {
            if model.canGoBack {
                Button("Back") { model.back() }
            }
            if controller.state.isOn {
                Button("Done") { close() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Done") { close() }
                Button("Turn On Now") { turnOnNow() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(model.helper == .ready ? .defaultAction : nil)
                    .disabled(model.helper != .ready || model.isTurningOn)
            }
        } else {
            if model.canGoBack {
                Button("Back") { model.back() }
            }
            Button(continueTitle) { model.advance() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(continueIsDefault ? .defaultAction : nil)
                .disabled(!model.canContinue)
        }
    }

    /// Return belongs to the step's own button while that is the thing to press: "Allow Notifications", not "Skip".
    private var continueIsDefault: Bool {
        model.canContinue && !(model.step == .notifications && model.notifications == .notAsked)
    }

    private var continueTitle: String {
        model.step == .notifications && model.notifications != .allowed ? "Skip" : "Continue"
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
                turnOnProblem = controller.notice ?? "ClamDown did not turn on."
            }
        }
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    var body: some View {
        StepLayout(
            icon: .app,
            title: "Welcome to ClamDown",
            text: "ClamDown keeps your MacBook working with the lid closed, so your agents keep going. It locks the screen, drives the fans, and switches itself off before a low battery or heat becomes a problem."
        ) {
            Text("Setup takes about a minute.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct HelperStep: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        StepLayout(
            icon: .symbol("gearshape.2.fill", .accentColor),
            title: "Allow the helper",
            text: "ClamDown needs a small background helper with administrator rights. It changes the sleep setting and drives the fans, and it does nothing else. macOS asks you to allow it once."
        ) {
            SetupCard {
                StatusRow(status: status) {
                    if let buttonTitle {
                        Button(buttonTitle) { Task { await model.allowHelper() } }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(model.isPreparingHelper)
                    }
                }
            }
        }
    }

    private var status: StatusInfo {
        if let error = model.helperError {
            return .init(symbol: "exclamationmark.triangle.fill", color: .red, title: "The helper is not set up", detail: error, detailColor: .red)
        }
        switch model.helper {
        case .ready:
            return .init(symbol: "checkmark.circle.fill", color: .green, title: "Allowed")
        case .requiresApproval:
            return .init(symbol: "clock.fill", color: .orange, title: "Waiting for you",
                         detail: "Turn on ClamDown in System Settings > General > Login Items & Extensions.")
        case .notRegistered, .unavailable:
            return .init(symbol: "circle.dashed", color: .secondary, title: "Not set up yet")
        }
    }

    private var buttonTitle: String? {
        if model.helperError != nil { return "Try Again" }
        switch model.helper {
        case .ready: return nil
        case .requiresApproval: return "Open Login Items"
        case .notRegistered, .unavailable: return "Allow…"
        }
    }
}

private struct NotificationsStep: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        StepLayout(
            icon: .symbol("bell.badge.fill", .accentColor),
            title: "Know when ClamDown switches off",
            text: "With the lid closed you cannot see the menu. A notification tells you when ClamDown switched itself off, for example at low battery or when the Mac got hot."
        ) {
            SetupCard {
                StatusRow(status: status) {
                    switch model.notifications {
                    case .notAsked:
                        Button("Allow Notifications") { Task { await model.allowNotifications() } }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(model.isRequestingNotifications)
                    case .denied:
                        Button("Open Notification Settings") {
                            model.openedNotificationSettings()
                            SystemSettings.openNotifications()
                        }
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
            .init(symbol: "bell", color: .secondary, title: "Not allowed yet")
        case .allowed:
            .init(symbol: "checkmark.circle.fill", color: .green, title: "Allowed")
        case .denied:
            .init(symbol: "bell.slash.fill", color: .orange, title: "Switched off",
                  detail: "Notifications for ClamDown are off in System Settings.")
        }
    }
}

private struct StartupStep: View {
    @ObservedObject var controller: ClamDownController
    let loginItem: LoginItem
    @State private var hasFans = false

    var body: some View {
        StepLayout(
            icon: .symbol("power", .accentColor),
            title: "Start with your Mac",
            text: "ClamDown can open in the menu bar when you log in, so it is ready when you need it."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                SetupCard {
                    LaunchAtLoginRow(controller: controller, loginItem: loginItem)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Label(protection.isEmpty ? "No protection is switched on" : "Protection is already on",
                          systemImage: "shield.lefthalf.filled")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                    if !protection.isEmpty {
                        SetupCard {
                            ForEach(Array(protection.enumerated()), id: \.offset) { index, item in
                                if index > 0 { RowDivider() }
                                ProtectionRow(icon: item.icon, text: item.text)
                            }
                        }
                    }
                    Text("You can change all of this in Settings.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
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
            items.append(("lock.laptopcomputer", "Locks the screen when the lid closes"))
        }
        if settings.batteryCutoffEnabled {
            items.append(("battery.25", "Switches off at \(settings.batteryCutoffPercent)% battery"))
        }
        if settings.thermalCutoff != .never {
            items.append(("thermometer.high", "Switches off when the Mac gets hot"))
        }
        if hasFans {
            switch settings.fanMode {
            case .curve: items.append(("fan", "Drives the fans from CPU temperature"))
            case .fullSpeed: items.append(("fan", "Runs the fans at full speed"))
            case .system: break
            }
        }
        return items
    }
}

private struct DoneStep: View {
    @ObservedObject var controller: ClamDownController

    var body: some View {
        StepLayout(
            icon: .symbol("checkmark", .green),
            title: "You're set",
            text: "ClamDown lives in the menu bar. Look for this icon:"
        ) {
            VStack(spacing: 18) {
                Image(systemName: controller.settings.menuBarIcon.offSymbol)
                    .font(.system(size: 20, weight: .regular))
                    .frame(width: 64, height: 36)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10)))
                Text("Turn it on before you close the lid.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Parts

/// The shared look of a step: a centered icon, title and explanation, with the step's own content below.
private struct StepLayout<Content: View>: View {
    enum Icon {
        case app
        case symbol(String, Color)
    }

    let icon: Icon
    let title: String
    let text: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            iconView
                .padding(.top, 34)
            Text(title)
                .font(.system(size: 26, weight: .bold))
                .multilineTextAlignment(.center)
                .padding(.top, 14)
            Text(text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 450)
                .padding(.top, 8)
            content
                .padding(.top, 20)
        }
        .padding(.horizontal, 36)
    }

    @ViewBuilder private var iconView: some View {
        switch icon {
        case .app:
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 76, height: 76)
        case .symbol(let name, let color):
            Image(systemName: name)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 60, height: 60)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(color.opacity(0.14)))
        }
    }
}

/// The rounded card of the settings window, without a title.
private struct SetupCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }
}

/// What a status row says: a colored symbol, a short title and an optional sentence under it.
private struct StatusInfo {
    let symbol: String
    let color: Color
    let title: String
    var detail: String?
    var detailColor: Color = .secondary
}

/// A state and, on the right, the action that changes it.
private struct StatusRow<Action: View>: View {
    let status: StatusInfo
    @ViewBuilder var action: Action

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: status.symbol)
                .font(.system(size: 18))
                .foregroundStyle(status.color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(status.title)
                    .fontWeight(.medium)
                if let detail = status.detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(status.detailColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            action
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
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
                .foregroundStyle(.green)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// One dot per step, the current one in the accent color.
private struct StepDots: View {
    let steps: [SetupStep]
    let current: SetupStep

    var body: some View {
        HStack(spacing: 7) {
            ForEach(steps, id: \.self) { step in
                Circle()
                    .fill(step == current ? Color.accentColor : Color.primary.opacity(0.18))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \((steps.firstIndex(of: current) ?? 0) + 1) of \(steps.count)")
    }
}
