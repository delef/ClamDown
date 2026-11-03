import Foundation
import WakeupHelperKit
import WakeupShared

private func log(_ message: String) {
    FileHandle.standardError.write(Data("WakeupHelper: \(message)\n".utf8))
}

/// Refuses to run (fail closed) when it cannot tell exactly who may talk to it.
private func fail(_ message: String) -> Never {
    log(message)
    exit(1)
}

/// Runs for the life of the process. It never returns, which keeps the listener,
/// its delegate and the watchdog timer alive.
private func runHelper() async -> Never {
    // <App>.app/Contents/MacOS/WakeupHelper -> three levels up is the app bundle.
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

    let core = HelperCore(
        runner: SystemPmsetRunner(),
        store: FileSavedStateStore(url: URL(fileURLWithPath: "/var/db/wakeup/state.json"))
    )
    // Put back anything a previous run left behind. A failure here must not stop the helper from serving.
    do { try await core.recoverOnStart() } catch { log("recovery on start failed: \(error)") }

    let listener = NSXPCListener(machServiceName: Identifiers.helperLabel(appBundleID: appBundleID))
    let delegate = HelperListenerDelegate(core: core)
    listener.setConnectionCodeSigningRequirement(requirement)
    listener.delegate = delegate
    listener.resume()

    let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    timer.schedule(deadline: .now() + 10, repeating: 10)
    timer.setEventHandler { Task { _ = await core.checkWatchdog() } }
    timer.resume()

    // Never resumed on purpose: keeps this frame, and everything above, alive.
    await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
    fatalError("unreachable")
}

Task { await runHelper() }
dispatchMain()
