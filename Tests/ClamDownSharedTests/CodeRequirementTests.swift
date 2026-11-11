import Testing
@testable import ClamDownShared

@Test func requirementPinsIdentifierAndTeam() {
    #expect(CodeRequirement.make(identifier: "app.clamdown", teamID: "ABCDE12345")
        == #"anchor apple generic and identifier "app.clamdown" and certificate leaf[subject.OU] = "ABCDE12345""#)
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
    #expect(Identifiers.helperLabel(appBundleID: "app.clamdown") == "app.clamdown.helper")
}
