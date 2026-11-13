import Testing
import ClamDownSensors

@Suite struct CPUTemperaturesTests {
    @Test func averageAndHottest() {
        let s = CPUTemperatures.summary([60, 70, 92])
        #expect(s.average == 74 && s.hottest == 92)
    }

    @Test func implausibleValuesAreDropped() {
        let s = CPUTemperatures.summary([0, 65, 140, 75])
        #expect(s.average == 70 && s.hottest == 75)
    }

    @Test func nothingPlausibleGivesNil() {
        let s = CPUTemperatures.summary([0, 200])
        #expect(s.average == nil && s.hottest == nil)
    }
}
