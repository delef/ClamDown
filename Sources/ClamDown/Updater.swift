import Combine
import Sparkle
import SwiftUI

/// Checks GitHub Releases for new versions through Sparkle and exposes the state the menu and Settings show.
///
/// The feed and the public key that verifies every update are in Info.plist (`SUFeedURL`, `SUPublicEDKey`).
/// Sparkle sends no system profile, so a check is a plain download of appcast.xml.
@MainActor
final class Updater: NSObject, ObservableObject {
    /// False while a check or an install is already running.
    @Published private(set) var canCheckForUpdates = false
    /// The version a scheduled check found, until the user deals with it.
    @Published private(set) var availableVersion: String?
    @Published var checksAutomatically = false {
        didSet {
            guard checksAutomatically != controller.updater.automaticallyChecksForUpdates else { return }
            controller.updater.automaticallyChecksForUpdates = checksAutomatically
        }
    }

    private var controller: SPUStandardUpdaterController!
    private var observers: Set<AnyCancellable> = []

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        let updater = controller.updater
        checksAutomatically = updater.automaticallyChecksForUpdates
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &observers)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self, self.checksAutomatically != value else { return }
                self.checksAutomatically = value
            }
            .store(in: &observers)
    }

    /// Shows Sparkle's window: the update found earlier, or the result of a fresh check.
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}

extension Updater: SPUStandardUserDriverDelegate {
    /// ClamDown lives in the menu bar, so a scheduled check must not pop a window over the user's work.
    /// Sparkle then leaves the reminder to us: the menu shows the new version until the user opens it.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        let version = update.displayVersionString
        let remind = !handleShowingUpdate && !state.userInitiated
        Task { @MainActor in self.availableVersion = remind ? version : nil }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor in self.availableVersion = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in self.availableVersion = nil }
    }
}
