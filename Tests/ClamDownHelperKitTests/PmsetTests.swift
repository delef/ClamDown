import Foundation
import Testing
@testable import ClamDownHelperKit

// Captured from a real Mac with `pmset -g custom`; keep the spacing.
private let customFixture = """
Battery Power:
 Sleep On Power Button 1
 lowpowermode         1
 sleep                1
AC Power:
 Sleep On Power Button 1
 lowpowermode         0
 sleep                0

"""

@Suite struct PmsetTests {
    @Test func argumentsAreExact() {
        #expect(PmsetCommand.setSleepDisabled(true).arguments == ["disablesleep", "1"])
        #expect(PmsetCommand.setSleepDisabled(false).arguments == ["disablesleep", "0"])
        #expect(PmsetCommand.setBatteryLowPowerMode(true).arguments == ["-b", "lowpowermode", "1"])
        #expect(PmsetCommand.setBatteryLowPowerMode(false).arguments == ["-b", "lowpowermode", "0"])
        #expect(PmsetCommand.readGlobal.arguments == ["-g"])
        #expect(PmsetCommand.sleepNow.arguments == ["sleepnow"])
        #expect(PmsetCommand.readCustom.arguments == ["-g", "custom"])
    }

    @Test func parsesSleepDisabled() {
        #expect(PmsetParser.sleepDisabled(fromGlobal: " SleepDisabled\t\t1\n lowpowermode         0\n") == true)
        #expect(PmsetParser.sleepDisabled(fromGlobal: " SleepDisabled\t\t0\n") == false)
    }

    @Test func sleepDisabledMissingIsNil() {
        #expect(PmsetParser.sleepDisabled(fromGlobal: " lowpowermode 0\n") == nil)
    }

    @Test func parsesBatteryLowPowerFromCustom() {
        #expect(PmsetParser.batteryLowPowerMode(fromCustom: customFixture) == true)
    }

    @Test func ignoresAcSection() {
        let fixture = "Battery Power:\n lowpowermode         0\nAC Power:\n lowpowermode         1\n"
        #expect(PmsetParser.batteryLowPowerMode(fromCustom: fixture) == false)
    }

    @Test func missingLowPowerKeyIsNil() {
        let fixture = "Battery Power:\n sleep                1\nAC Power:\n lowpowermode         1\n"
        #expect(PmsetParser.batteryLowPowerMode(fromCustom: fixture) == nil)
    }

    @Test func runnerReadsRealPmset() throws {
        let output = try SystemPmsetRunner().run(.readGlobal)
        #expect(!output.isEmpty)
    }

    @Test func runnerThrowsOnNonZeroExit() {
        #expect(throws: PmsetError.failed(status: 1, output: "")) {
            try SystemPmsetRunner(executablePath: "/usr/bin/false").run(.readGlobal)
        }
    }

    @Test func runnerReturnsTheOutput() throws {
        // echo prints the arguments pmset would get.
        #expect(try SystemPmsetRunner(executablePath: "/bin/echo").run(.readGlobal) == "-g\n")
    }

    /// A pmset that never ends is stopped, so it cannot block the helper's actor, its watchdog and the fans.
    @Test func runnerStopsAPmsetThatHangs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("hang")
        try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let start = ContinuousClock.now
        #expect(throws: PmsetError.timedOut) {
            try SystemPmsetRunner(executablePath: script.path, timeout: .milliseconds(200)).run(.readGlobal)
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }
}
