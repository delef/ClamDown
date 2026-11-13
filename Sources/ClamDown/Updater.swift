import ClamDownAppKit
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
    @Published private(set) var canCheckForUpdates = false {
        didSet { refreshStatus() }
    }
    /// What Sparkle has found: the version About shows and the reminder the menu shows.
    private var finding = UpdateFinding() {
        didSet {
            if availableVersion != finding.reminderVersion { availableVersion = finding.reminderVersion }
            refreshStatus()
        }
    }
    /// The version a scheduled check found quietly, for the menu's "Update to X…", until the user deals with it.
    @Published private(set) var availableVersion: String?
    /// What the About page says about updates. Sparkle's state, mapped: a version waiting, a check running, or none.
    @Published private(set) var status: UpdateStatus = .upToDate(lastCheck: nil)
    @Published var checksAutomatically = false {
        didSet {
            guard checksAutomatically != controller.updater.automaticallyChecksForUpdates else { return }
            controller.updater.automaticallyChecksForUpdates = checksAutomatically
        }
    }

    private var controller: SPUStandardUpdaterController!
    private var observers: Set<AnyCancellable> = []

    /// - Parameter starts: false leaves Sparkle idle, for a debug preview that must not check for anything.
    init(starts: Bool = true) {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: starts, updaterDelegate: self, userDriverDelegate: self)
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

    #if DEBUG
    /// A status to show in place of Sparkle's, for a debug picture of the About page.
    var previewStatus: UpdateStatus? {
        didSet { refreshStatus() }
    }
    #endif

    /// Maps Sparkle's state to `status`. Sparkle does not publish the date of the last check, so the About page
    /// calls this when it appears as well.
    func refreshStatus() {
        guard controller != nil else { return }
        #if DEBUG
        if let previewStatus {
            status = previewStatus
            return
        }
        #endif
        if let version = finding.foundVersion {
            status = .available(version)
        } else if !canCheckForUpdates {
            status = .checking
        } else {
            status = .upToDate(lastCheck: controller.updater.lastUpdateCheckDate)
        }
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
        let event = UpdateFinding.Event.found(update.displayVersionString, userInitiated: state.userInitiated,
                                              shownBySparkle: handleShowingUpdate)
        Task { @MainActor in self.finding.handle(event) }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor in self.finding.handle(.userAttention) }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in self.finding.handle(.sessionFinished) }
    }
}

/// Sparkle calls these on the main thread. They tell About when a found version is no longer waiting.
extension Updater: SPUUpdaterDelegate {
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        finding.handle(.noUpdateFound)
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        finding.handle(.installing)
    }
}
