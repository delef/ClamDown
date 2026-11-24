import Foundation
import ClamDownHelperKit
import ClamDownSensors
import ClamDownShared

/// Skipped ticks in a row after which the helper gives up on its stuck actor and exits.
private let stuckTickLimit = 20

/// launchd sends a daemon's own output nowhere, so everything worth keeping goes here; see `SystemJournal`.
/// The fan trace sits with the system's logs, where an admin user and Console can read it.
private let journal = SystemJournal(trace: FanTraceFile(directory: URL(fileURLWithPath: "/Library/Logs/ClamDown")))

/// Refuses to run (fail closed) when it cannot tell exactly who may talk to it.
private func fail(_ message: String) -> Never {
    journal.failure(.process, "refusing to serve, exiting: \(message)")
    exit(1)
}

/// Runs for the life of the process. It never returns, which keeps the listener,
/// its delegate and the watchdog timer alive.
private func runHelper() async -> Never {
    // <App>.app/Contents/MacOS/ClamDownHelper -> three levels up is the app bundle.
    let executableURL = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
    let appURL = executableURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let info = Bundle(url: appURL)?.infoDictionary
    journal.change(.process, "started, version \(info?["CFBundleShortVersionString"] as? String ?? "unknown")"
        + " (build \(info?["CFBundleVersion"] as? String ?? "unknown"))")
    let fans = SMCFanHardware()
    if fans == nil { journal.failure(.fans, "cannot open the SMC; macOS keeps the fans") }
    // Recovery runs before any check that can exit, so a helper that refuses to serve
    // still puts the user's sleep setting back.
    let core = HelperCore(
        runner: SystemPmsetRunner(),
        store: FileSavedStateStore(url: URL(fileURLWithPath: "/var/db/clamdown/state.json")),
        originals: FileOriginalSettingsStore(url: URL(fileURLWithPath: "/var/db/clamdown/original.json")),
        fans: fans,
        lid: SystemLid(),
        idle: SystemIdle(),
        thermal: SystemThermalState(),
        journal: journal
    )
    // A failure here must not stop the helper from serving. The core has written it down.
    do { try await core.recoverOnStart() } catch {}

    guard let appBundleID = Bundle(url: appURL)?.bundleIdentifier else {
        fail("cannot read the app bundle identifier from \(appURL.path)")
    }
    guard let teamID = SigningIdentity.currentTeamID() else {
        fail("this helper is not signed with a Team ID")
    }
    guard let requirement = CodeRequirement.make(identifier: appBundleID, teamID: teamID) else {
        fail("bundle identifier or Team ID has an unexpected format")
    }

    // launchd stops the daemon with SIGTERM: put the sleep setting back before exiting.
    // SIGKILL cannot be caught; the recovery on the next start covers that case.
    // A dispatch source is cancelled once released, so the sources are kept alive below with everything else.
    let signalSources = [SIGTERM, SIGINT].map { sig in
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global(qos: .utility))
        source.setEventHandler {
            Task {
                do { try await core.shutdown() } catch {}  // the core has written it down
                journal.change(.process, "exiting on signal \(sig)")
                exit(0)
            }
        }
        source.resume()
        return source
    }

    let listener = NSXPCListener(machServiceName: Identifiers.helperLabel(appBundleID: appBundleID))
    let delegate = HelperListenerDelegate(core: core)
    listener.setConnectionCodeSigningRequirement(requirement)
    listener.delegate = delegate
    listener.resume()

    let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    // Every 3 seconds: the watchdog check, then the fan speeds (which also hands the fans back once the mode is off).
    // A tick still running makes the next one skip, so a slow SMC call cannot build a queue that delays heartbeats.
    let tickGate = TickGate()
    timer.schedule(deadline: .now() + 3, repeating: 3)
    timer.setEventHandler {
        let started = tickGate.start {
            _ = await core.checkWatchdog()
            await core.updateFans()
        }
        // A tick stuck this long (20 ticks, a minute) means the helper's actor is stuck, and with it the watchdog
        // and the fans. Exit, so launchd starts a fresh helper whose recovery puts sleep and the fans back.
        if !started, tickGate.skippedInARow >= stuckTickLimit {
            journal.failure(.process, "a tick has been running for over a minute; exiting so launchd starts the helper again")
            exit(1)
        }
    }
    timer.resume()

    // Never resumed on purpose. The objects used after the await stay alive while it waits;
    // a live frame alone does not guarantee that, because Swift may release an object after its last use.
    await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
    withExtendedLifetime((listener, delegate, timer, signalSources)) {}
    fatalError("unreachable")
}

Task { await runHelper() }
dispatchMain()
