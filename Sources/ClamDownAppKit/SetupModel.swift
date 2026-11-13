import Combine

/// What the setup assistant shows and what its buttons do. The views only draw this.
@MainActor
public final class SetupModel: ObservableObject {
    public let mode: SetupMode
    @Published public private(set) var step: SetupStep
    /// The helper's state as the Helper step shows it. `refreshHelper()` keeps it current.
    @Published public private(set) var helper: HelperAvailability
    /// A plain sentence when registering the helper failed. Cleared by the next attempt and by a ready helper.
    @Published public private(set) var helperError: String?
    @Published public private(set) var notifications: NotificationPermission = .notAsked
    /// Each is true while that button's work runs, so it cannot be pressed twice. They are separate on purpose:
    /// the notification prompt can wait for an answer for minutes, and must not disable the other buttons.
    @Published public private(set) var isPreparingHelper = false
    @Published public private(set) var isRequestingNotifications = false
    @Published public private(set) var isTurningOn = false

    private let controller: ClamDownController
    private let store: SetupStoring
    private let authorizer: NotificationAuthorizing
    /// True after the user went to System Settings from the Notifications step. If the permission then turns up
    /// allowed, they asked for notifications there, the same as with the "Allow Notifications" button.
    private var wentToNotificationSettings = false

    public init(presentation: SetupPresentation, controller: ClamDownController, store: SetupStoring,
                notifications: NotificationAuthorizing) {
        mode = presentation.mode
        step = presentation.step
        self.controller = controller
        self.store = store
        authorizer = notifications
        controller.refreshHelperAvailability()
        helper = controller.helperAvailability
    }

    public var steps: [SetupStep] { SetupFlow.steps(for: mode) }

    /// False on the last step, and on the Helper step until the helper is ready.
    public var canContinue: Bool {
        SetupFlow.next(after: step, mode: mode) != nil && SetupFlow.canContinue(from: step, helper: helper)
    }

    public var canGoBack: Bool { SetupFlow.previous(before: step, mode: mode) != nil }

    public func advance() {
        guard canContinue, let next = SetupFlow.next(after: step, mode: mode) else { return }
        step = next
        if next == .done { store.completed = true }
    }

    public func back() {
        guard let previous = SetupFlow.previous(before: step, mode: mode) else { return }
        step = previous
    }

    /// The "Allow..." button: registers the helper and, when macOS wants the user's approval, opens Login Items.
    public func allowHelper() async {
        guard !isPreparingHelper else { return }
        isPreparingHelper = true
        defer { isPreparingHelper = false }
        helperError = nil
        let result = await controller.prepareHelper()
        adopt(controller.helperAvailability)
        switch result {
        case .ready: break
        case .needsApproval: controller.openHelperApproval()
        case .failed(let message): helperError = message
        }
    }

    /// Reads the helper's state again. Returns true at the moment it becomes ready, so the window can come forward.
    @discardableResult
    public func refreshHelper() -> Bool {
        controller.refreshHelperAvailability()
        return adopt(controller.helperAvailability)
    }

    /// Reads the notification permission. Never shows a prompt.
    public func refreshNotifications() async {
        notifications = await authorizer.permission()
        guard wentToNotificationSettings, notifications == .allowed else { return }
        wentToNotificationSettings = false
        await switchNotificationsSettingOn()
    }

    /// Call when "Open Notification Settings" is pressed.
    public func openedNotificationSettings() {
        wentToNotificationSettings = true
    }

    /// The "Allow Notifications" button. The user asked for notifications, so the setting is switched on with them.
    public func allowNotifications() async {
        guard !isRequestingNotifications else { return }
        isRequestingNotifications = true
        defer { isRequestingNotifications = false }
        notifications = await authorizer.requestPermission()
        if notifications == .allowed { await switchNotificationsSettingOn() }
    }

    private func switchNotificationsSettingOn() async {
        guard !controller.settings.notificationsEnabled else { return }
        var updated = controller.settings
        updated.notificationsEnabled = true
        await controller.updateSettings(updated)
    }

    /// "Turn On Now": finishes the Turn On that waited for approval, or starts one like the menu does.
    public func turnOnNow() async {
        guard !isTurningOn else { return }
        isTurningOn = true
        defer { isTurningOn = false }
        await controller.resumeTurnOn()
    }

    /// Call when the window closes.
    public func closed() {
        controller.dropPendingTurnOn()
    }

    /// A ready helper is the whole point of setup, so reaching it counts as finished however the user got there.
    @discardableResult
    private func adopt(_ availability: HelperAvailability) -> Bool {
        let becameReady = availability == .ready && helper != .ready
        if availability != helper { helper = availability }
        if availability == .ready {
            helperError = nil
            if !store.completed { store.completed = true }
        }
        return becameReady
    }
}
