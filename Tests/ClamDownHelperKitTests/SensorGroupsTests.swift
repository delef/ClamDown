import Testing
import ClamDownSensors
import ClamDownShared

@Suite struct SensorGroupsTests {
    @Test func keysFallIntoTheKnownGroups() {
        #expect(SensorKeys.group(of: "Tp01") == .cpu)
        #expect(SensorKeys.group(of: "Te05") == .cpu)
        #expect(SensorKeys.group(of: "Tg0f") == .gpu)
        #expect(SensorKeys.group(of: "TB0T") == .battery)
        #expect(SensorKeys.group(of: "TB2T") == .battery)
        #expect(SensorKeys.group(of: "TH0x") == .ssd)
        #expect(SensorKeys.group(of: "TH0b") == .ssd)
        #expect(SensorKeys.group(of: "TW0P") == .wifi)
        #expect(SensorKeys.group(of: "TaLP") == .airflow)
        #expect(SensorKeys.group(of: "TaRF") == .airflow)
    }

    /// Some of these are frozen on the owner's M3 Pro; their maximum would keep the fans high for nothing.
    @Test func otherFamiliesAreIgnored() {
        for key in ["Tf16", "Tf26", "TV0s", "TR0Z", "Ts0P", "Th0H", "TP0x", "TB3T", "TH1a", "TW1P", "TaXX", "F0Ac"] {
            #expect(SensorKeys.group(of: key) == nil, "\(key)")
        }
    }

    @Test func eachGroupGivesItsHottestPlausibleValue() {
        let summary = SensorKeys.hottestByGroup([
            .cpu: [60, 91.5, 70],
            .battery: [33, 0, 140],
            .ssd: [0, 200],
            .gpu: [],
        ])
        #expect(summary == [.cpu: 91.5, .battery: 33])
    }

    @Test func overallHottestNamesItsGroup() {
        let hottest = SensorGroup.hottest(in: [.cpu: 48, .battery: 52, .ssd: 41])
        #expect(hottest?.group == .battery)
        #expect(hottest?.celsius == 52)
        #expect(SensorGroup.hottest(in: [:]) == nil)
    }

    /// Two groups at the same value always give the same answer: the one listed first.
    @Test func aTieGoesToTheEarlierGroup() {
        #expect(SensorGroup.hottest(in: [.wifi: 50, .cpu: 50, .gpu: 50])?.group == .cpu)
    }

    @Test func readingCarriesTheGroupsAndTheirHottest() {
        let reading = HardwareReading(cpuTemperature: 45, hottestCPUTemperature: 48, fans: [], lidClosed: true,
                                      groupTemperatures: [.cpu: 48, .battery: 51])
        #expect(reading.hottestTemperature == 51)
        #expect(reading.hottestGroup == .battery)
        let bare = HardwareReading(cpuTemperature: 45, fans: [], lidClosed: true)
        #expect(bare.hottestTemperature == nil && bare.hottestGroup == nil)
    }
}
