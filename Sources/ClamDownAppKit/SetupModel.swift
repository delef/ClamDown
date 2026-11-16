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
    /// Whether the allowed helper runs. Nil while macOS does not allow it. `refreshHelper()` keeps it current.
    @Published public private(set) var helperRun: HelperRunCheck?
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
    /// True after the user went to Login Items because launchd would not start the helper.
    private var wentToLoginItems = false

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
        SetupFlow.next(after: step, mode: mode) != nil
            && SetupFlow.canContinue(from: step, helper: helper, helperAnswers: helperRun == .answers)
    }

    /// Allowed by macOS and answering: the only state in which the helper can do its work.
    public var helperWorks: Bool { helper == .ready && helperRun == .answers }

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
        await checkRun()
        switch result {
        case .ready: break
        case .needsApproval: controller.openHelperApproval()
        case .failed(let message): helperError = message
        }
    }

    /// Reads the helper's state again. Returns true at the moment it starts to work, so the window can come forward.
    /// A Turn On that stopped to send the user to System Settings then finishes by itself.
    @discardableResult
    public func refreshHelper() async -> Bool {
        let worked = helperWorks
        controller.refreshHelperAvailability()
        adopt(controller.helperAvailability)
        await checkRun()
        let startedWorking = !worked && helperWorks
        if startedWorking, controller.pendingTurnOn != nil { await turnOnNow() }
        return startedWorking
    }

    /// Asks an allowed helper whether it runs, until it has answered once.
    private func checkRun() async {
        guard helper == .ready else {
            helperRun = nil
            return
        }
        guard helperRun != .answers else { return }
        let run = await controller.checkHelperRuns()
        if run != helperRun { helperRun = run }
        // A working helper is the whole point of setup, so reaching it counts as finished however the user got there.
        if run == .answers, !store.completed { store.completed = true }
    }

    /// "Open Login Items" while launchd will not start the helper: usually ClamDown is switched off there.
    public func openLoginItems() {
        wentToLoginItems = true
        controller.openHelperApproval()
    }

    /// Call when the app becomes active. After a trip to Login Items, launchd still keeps the old job, which cannot
    /// start, even once ClamDown is turned on there. So the helper is registered afresh once, by finishing the
    /// remembered Turn On or, without one, by reinstalling it.
    public func returnedToTheApp() async {
        guard wentToLoginItems, helper == .ready, helperRun == .startFailed, !controller.state.isOn else { return }
        wentToLoginItems = false
        if controller.pendingTurnOn != nil {
            await turnOnNow()
        } else {
            await controller.reinstallHelper()
        }
        helperRun = nil
        await checkRun()
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

    private func adopt(_ availability: HelperAvailability) {
        if availability != helper { helper = availability }
        if availability == .ready { helperError = nil }
    }
}
