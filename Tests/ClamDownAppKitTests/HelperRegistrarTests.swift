import ServiceManagement
import Testing
@testable import ClamDownAppKit

@Suite struct HelperRegistrarTests {
    @Test func mapsServiceStatus() {
        #expect(HelperAvailability(.enabled) == .ready)
        #expect(HelperAvailability(.requiresApproval) == .requiresApproval)
        #expect(HelperAvailability(.notRegistered) == .notRegistered)
        if case .unavailable = HelperAvailability(.notFound) {} else {
            Issue.record("notFound must map to .unavailable")
        }
    }
}
