import Testing
@testable import ClamDownAppKit

@Suite struct SettingsPaneTests {
    @Test func restoresKnownPane() { #expect(SettingsPane.restored(from: "cooling") == .cooling) }

    @Test func unknownPaneOpensGeneral() {
        #expect(SettingsPane.restored(from: "cooling-advanced") == .general)
        #expect(SettingsPane.restored(from: "") == .general)
        #expect(SettingsPane.restored(from: nil) == .general)
    }

    @Test func onlyAboutStartsAGroup() { #expect(SettingsPane.allCases.filter(\.startsGroup) == [.about]) }

    @Test func everyPaneHasATitleAndSymbol() {
        for pane in SettingsPane.allCases {
            #expect(!pane.title.isEmpty && !pane.symbol.isEmpty)
        }
        #expect(SettingsPane.allCases.map(\.symbol) == [
            "gearshape", "moon.zzz", "shield.lefthalf.filled", "fan", "paintbrush", "wrench.and.screwdriver", "info.circle",
        ])
    }

    @Test func subtitlesComeFromTheSketch() {
        #expect(SettingsPane.general.subtitle == "Startup, notifications and a fresh start.")
        #expect(SettingsPane.sleep.subtitle == "How long ClamDown keeps the Mac awake, and what it does meanwhile.")
        #expect(SettingsPane.protection.subtitle == "When ClamDown lets a Mac in a bag go to sleep.")
        #expect(SettingsPane.cooling.subtitle == "ClamDown takes the fans and cools early, because a closed Mac has little airflow.")
        #expect(SettingsPane.appearance.subtitle == "How ClamDown looks in the menu bar.")
        #expect(SettingsPane.helper.subtitle
            == "A small background helper with administrator rights changes the sleep setting and drives the fans. It does nothing else.")
        #expect(SettingsPane.about.subtitle.isEmpty)
    }
}
