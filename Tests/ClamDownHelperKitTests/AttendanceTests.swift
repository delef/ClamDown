import ClamDownSensors
import Testing

@Suite struct AttendanceTests {
    private static let closedForSleep = LidState(closed: true, closingCausesSleep: true)

    @Test func closedQuietAndNoDisplayIsUnattended() {
        #expect(Attendance(lid: Self.closedForSleep, idle: .seconds(60), externalDisplay: false) == .unattended)
        #expect(Attendance(lid: Self.closedForSleep, idle: .seconds(3600), externalDisplay: false) == .unattended)
    }

    /// The lid values alone can be stale. Someone who typed seconds ago is still there, or has only just left.
    @Test func recentInputMeansLookAgainOnceAMinuteHasPassed() {
        #expect(Attendance(lid: Self.closedForSleep, idle: .seconds(5), externalDisplay: false) == .leaving(.seconds(55)))
        #expect(Attendance(lid: Self.closedForSleep, idle: .zero, externalDisplay: false) == .leaving(.seconds(60)))
    }

    @Test func externalDisplayMeansSomeoneMayBeWorking() {
        #expect(Attendance(lid: Self.closedForSleep, idle: .seconds(3600), externalDisplay: true) == .attended)
    }

    @Test(arguments: [
        LidState(closed: false, closingCausesSleep: true),
        LidState(closed: true, closingCausesSleep: false),
        nil,
    ] as [LidState?])
    func lidThatIsNotClosedForSleepIsAttended(lid: LidState?) {
        #expect(Attendance(lid: lid, idle: .seconds(3600), externalDisplay: false) == .attended)
    }

    /// What cannot be read must never be taken as "nobody is there".
    @Test func unknownIdleTimeIsAttended() {
        #expect(Attendance(lid: Self.closedForSleep, idle: nil, externalDisplay: false) == .attended)
    }
}
