import Foundation
import ClamDownHelperKit
import ClamDownSensors
import ClamDownShared

private func log(_ message: String) {
    FileHandle.standardError.write(Data("ClamDownHelper: \(message)\n".utf8))
}

/// Refuses to run (fail closed) when it cannot tell exactly who may talk to it.
private func fail(_ message: String) -> Never {
    log(message)
    exit(1)
}

/// Runs for the life of the process. It never returns, which keeps the listener,
/// its delegate and the watchdog timer alive.
private func runHelper() async -> Never {
    // Recovery runs before any check that can exit, so a helper that refuses to serve
    // still puts the user's sleep setting back.
    let core = HelperCore(
        runner: SystemPmsetRunner(),
        store: FileSavedStateStore(url: URL(fileURLWithPath: "/var/db/clamdown/state.json")),
        fans: SMCFanHardware()
    )
    // A failure here must not stop the helper from serving.
    do { try await core.recoverOnStart() } catch { log("recovery on start failed: \(error)") }

    // <App>.app/Contents/MacOS/ClamDownHelper -> three levels up is the app bundle.
    let executableURL = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
    let appURL = executableURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
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
                do { try await core.disable() } catch { log("disable on signal failed: \(error)") }
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
    timer.schedule(deadline: .now() + 3, repeating: 3)
    timer.setEventHandler {
        Task {
            _ = await core.checkWatchdog()
            await core.updateFans()
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
