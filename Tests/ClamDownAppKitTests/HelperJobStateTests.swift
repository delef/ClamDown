import Testing
@testable import ClamDownAppKit

/// `launchctl print system/<label>` as seen on macOS 27. Its format is not documented, so anything unexpected
/// reads as unknown, and the controller then simply waits as before.
@Suite struct HelperJobStateTests {
    static let spawnFailed = """
        system/app.clamdown.helper = {
        \tactive count = 0
        \tpath = (submitted by smd.16871)
        \ttype = Submitted
        \tstate = spawn scheduled

        \tprogram identifier = Contents/MacOS/ClamDownHelper (mode: 2)
        \truns = 33
        \tlast exit code = 78: EX_CONFIG

        \tresource coalition = {
        \t\tstate = active
        \t}
        \tjob state = spawn failed
        \tproperties = partial import | keepalive | runatload | resolve program
        }
        """

    static let running = """
        system/app.clamdown.helper = {
        \tactive count = 1
        \tstate = running

        \tpid = 47100
        \truns = 1
        \tlast exit code = (never exited)
        \tjob state = running
        }
        """

    @Test func aJobThatCannotSpawnIsRead() {
        #expect(HelperJobState.parse(output: Self.spawnFailed, status: 0) == .spawnFailed(reason: "78: EX_CONFIG"))
    }

    @Test func aRunningJobIsRead() {
        #expect(HelperJobState.parse(output: Self.running, status: 0) == .running)
    }

    /// The nested `state = active` of a coalition is not the job's state.
    @Test func onlyTheJobsOwnStateCounts() {
        let output = "system/x = {\n\tstate = spawn scheduled\n\tresource coalition = {\n\t\tstate = active\n\t}\n}"
        #expect(HelperJobState.parse(output: output, status: 0) == .starting)
    }

    @Test func aCodeSigningRefusalNamesItsReason() {
        let output = Self.spawnFailed.replacingOccurrences(
            of: "\tlast exit code = 78: EX_CONFIG",
            with: "\tlast exit code = 78: EX_CONFIG\n\tlast exit reason = OS_REASON_CODESIGNING | Launch Constraint Violation")
        #expect(HelperJobState.parse(output: output, status: 0)
            == .spawnFailed(reason: "OS_REASON_CODESIGNING | Launch Constraint Violation"))
    }

    @Test func aMissingServiceOrAnythingElseIsUnknown() {
        #expect(HelperJobState.parse(output: "Bad request.\nCould not find service", status: 113) == .unknown)
        #expect(HelperJobState.parse(output: "", status: 0) == .unknown)
        #expect(HelperJobState.parse(output: "something new", status: 0) == .unknown)
    }
}
