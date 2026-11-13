import Foundation
import Testing
@testable import ClamDownAppKit

@Suite struct AboutInfoTests {
    private let info = AboutInfo(appVersion: "0.1.3", build: "4", macOSVersion: "27.2.1")

    @Test func versionLine() { #expect(info.versionLine == "Version 0.1.3 (4)") }

    @Test func clipboard() { #expect(info.clipboardText == "ClamDown 0.1.3 (4), macOS 27.2.1") }

    @Test func reportURLCarriesBothVersions() {
        let body = URLComponents(url: info.reportProblemURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "body" }?.value
        #expect(info.reportProblemURL.absoluteString.hasPrefix("https://github.com/delef/ClamDown/issues/new?"))
        #expect(body?.contains("ClamDown 0.1.3 (4)") == true && body?.contains("macOS 27.2.1") == true)
        #expect(body == "\n\n---\nClamDown 0.1.3 (4)\nmacOS 27.2.1")
    }

    @Test func links() {
        #expect(AboutInfo.website.absoluteString == "https://clamdown.app")
        #expect(AboutInfo.releaseNotes.absoluteString == "https://github.com/delef/ClamDown/releases")
        #expect(AboutInfo.sourceCode.absoluteString == "https://github.com/delef/ClamDown")
    }

    @Test func updateStatusTitles() {
        #expect(UpdateStatus.available("0.1.4").title() == "Version 0.1.4 is available")
        #expect(UpdateStatus.checking.title() == "Checking…")
        #expect(UpdateStatus.upToDate(lastCheck: nil).title() == "You have the latest version")
    }

    @Test func neverCheckedHasNoDetail() { #expect(UpdateStatus.upToDate(lastCheck: nil).detail(now: .now) == nil) }

    @Test func otherStatesHaveNoDetail() {
        #expect(UpdateStatus.checking.detail(now: .now) == nil)
        #expect(UpdateStatus.available("0.1.4").detail(now: .now) == nil)
    }

    @Test func checkedDetailIsRelative() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let detail = UpdateStatus.upToDate(lastCheck: now.addingTimeInterval(-300)).detail(now: now)
        #expect(detail?.hasPrefix("Checked ") == true && detail?.contains("5") == true)
    }
}
