import Testing
@testable import WakeupShared

@Test func requirementPinsIdentifierAndTeam() {
    #expect(CodeRequirement.make(identifier: "com.example.wakeup", teamID: "ABCDE12345")
        == #"anchor apple generic and identifier "com.example.wakeup" and certificate leaf[subject.OU] = "ABCDE12345""#)
}

@Test func rejectsQuoteInIdentifier() {
    #expect(CodeRequirement.make(identifier: #"a" or "b"#, teamID: "ABCDE12345") == nil)
}

@Test func rejectsMalformedTeamID() {
    for t in ["", "abcde12345", "ABCDE1234", "ABCDE123456", "ABC DE1234"] {
        #expect(CodeRequirement.make(identifier: "x.y", teamID: t) == nil)
    }
}

@Test func currentTeamIDIsNilOrWellFormed() {
    // The test runner is usually unsigned, so nil is fine; a value must look like a Team ID.
    if let id = SigningIdentity.currentTeamID() {
        #expect(CodeRequirement.make(identifier: "x.y", teamID: id) != nil)
    }
}

@Test func helperLabelAppendsHelper() {
    #expect(Identifiers.helperLabel(appBundleID: "com.example.wakeup") == "com.example.wakeup.helper")
}
