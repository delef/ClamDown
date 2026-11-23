import Foundation
import Testing
import ClamDownSensors
import ClamDownShared
@testable import ClamDownHelperKit

/// Replays sensor recordings from real Macs (`ClamDownFanProbe sensors <seconds>`, the timestamp and group columns;
/// the newer ones also carry the confirmed die zones as `zone.cpu` and `zone.gpu`)
/// through the helper, one reading a second, with the default settings. Each recording is checked against rules that
/// must hold whatever the temperatures do. Add the recording of every new situation, such as a Mac in a bag.
@Suite struct SensorTraceTests {
    static let traces = ["m3-pro-desk-load", "m3-pro-desk-idle", "m3-pro-desk-lid-closed",
                         "m3-pro-desk-burst-and-light-load", "m3-pro-desk-heavy-load"]

    struct Sample {
        var groups: [SensorGroup: Double]
        var zones: [SensorGroup: Double]
    }

    static func load(_ name: String) throws -> [Sample] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "csv", subdirectory: "Fixtures"))
        let lines = try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline)
        let header = try #require(lines.first).split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        return lines.dropFirst().map { line in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            var groups: [SensorGroup: Double] = [:]
            var zones: [SensorGroup: Double] = [:]
            for (column, field) in zip(header, fields) {
                guard let celsius = Double(field) else { continue }
                if let group = SensorGroup(rawValue: column) { groups[group] = celsius }
                if column.hasPrefix("zone."), let group = SensorGroup(rawValue: String(column.dropFirst(5))) {
                    zones[group] = celsius
                }
            }
            return Sample(groups: groups, zones: zones)
        }
    }

    /// Two fans with the range of a 14-inch MacBook Pro.
    private static let fanRange = (minimum: 1350.0, maximum: 5350.0)

    @Test(arguments: traces) func helperKeepsItsRulesThroughARealRecording(name: String) async throws {
        let samples = try Self.load(name)
        try #require(samples.count >= 30, "a recording needs at least 30 readings")
        let fans = FakeFans(fans: (0..<2).map {
            FanReading(rpm: Self.fanRange.minimum, minimum: Self.fanRange.minimum, maximum: Self.fanRange.maximum, index: $0)
        })
        fans.followsTargets = true
        let t0 = SuspendingClock.now
        let core = HelperCore(runner: FakeRunner(), store: FakeStore(), originals: FakeOriginalStore(), fans: fans, fanStepDown: 150)
        try await core.enable(lowPowerOnBattery: false, now: t0)
        let policy = FanPolicy(points: StandardCurve.points(start: StandardCurve.defaultStart, full: StandardCurve.defaultFull),
                               onlyWhenLidClosed: true)
        var previous: [Double]?
        var cpuInputs: ClosedRange<Double>?
        for (second, sample) in samples.enumerated() {
            for group in SensorGroup.allCases {
                fans.set(group: group, sample.groups[group])
                fans.set(zone: group, sample.zones[group])
            }
            fans.set(temperature: sample.groups[.cpu])
            fans.set(hottest: sample.groups[.cpu])
            let now = t0.advanced(by: .seconds(second))
            if second == 0 { try await core.setFanPolicy(policy, now: now) } else { await core.updateFans(now: now) }

            let status = await core.coolingStatus()
            #expect(status.control == .controlling, "second \(second)")
            let targets = try #require(fans.targets.last, "second \(second)")
            let followed = try #require(status.hottestTemperature, "second \(second)")
            // The case-side groups count as read, so a Mac warming in a bag reaches the fans at once.
            let caseSide = sample.groups.filter { !SustainedTemperatures.averagedGroups.contains($0.key) }
            if let warmest = SensorGroup.hottest(in: caseSide)?.celsius { #expect(followed >= warmest, "second \(second)") }
            // An average of the CPU's input never leaves the range of what that input has read.
            let cpuInput = try #require(sample.zones[.cpu] ?? sample.groups[.cpu])
            let inputs = cpuInputs.map { min($0.lowerBound, cpuInput)...max($0.upperBound, cpuInput) } ?? cpuInput...cpuInput
            cpuInputs = inputs
            let followedCPU = try #require(status.groupTemperatures[.cpu])
            #expect(inputs.contains(followedCPU), "second \(second): CPU \(followedCPU) outside \(inputs)")
            let wanted = status.override == nil ? policy.speed(at: followed) : 100
            let wantedRPM = FanDecision.speed(percent: wanted, fan: FanReading(rpm: 0, minimum: Self.fanRange.minimum,
                                                                             maximum: Self.fanRange.maximum))
            for (fan, rpm) in targets.enumerated() {
                // Never under what the curve, the floor and the overrides ask for, never outside the range.
                #expect(rpm >= wantedRPM - 0.001, "fan \(fan) at second \(second): \(rpm) < \(wantedRPM)")
                #expect(rpm >= Self.fanRange.minimum && rpm <= Self.fanRange.maximum)
                // Falls by at most 150 rpm per 3 seconds: 50 rpm per reading.
                if let before = previous?[fan] { #expect(before - rpm <= 50.001, "fan \(fan) fell too fast at second \(second)") }
            }
            if (sample.groups[.battery] ?? 0) >= 45 { #expect(status.override == .hotBattery || status.override == .hotCore) }
            previous = targets
        }
    }

    /// The airflow sensors sit by the heatsink and follow the chips' load, not how warm the case feels: the owner's
    /// fans ran at full speed at about 50 °C while the case felt cold (2026-11-23). A policy from 0.1.3, which still
    /// carries the case rule that drove the fans by them, must leave the fans on the curve.
    @Test func hotAirflowSensorsAloneDoNotRunTheFansAtFullSpeed() async throws {
        let samples = try Self.load("m3-pro-desk-heavy-load")
        try #require(samples.contains { ($0.groups[.airflow] ?? 0) >= 44 }, "the recording needs hot airflow sensors")
        let fans = FakeFans(fans: (0..<2).map {
            FanReading(rpm: Self.fanRange.minimum, minimum: Self.fanRange.minimum, maximum: Self.fanRange.maximum, index: $0)
        })
        fans.followsTargets = true
        let t0 = SuspendingClock.now
        let core = HelperCore(runner: FakeRunner(), store: FakeStore(), originals: FakeOriginalStore(), fans: fans, fanStepDown: 150)
        try await core.enable(lowPowerOnBattery: false, now: t0)
        // The owner's curve, 50 to 85 °C, as a 0.1.3 app sends it.
        let sent = #"{"points":[{"temperature":50,"speed":0},{"temperature":85,"speed":100}],"onlyWhenLidClosed":true,"caseRamp":{"start":38,"full":44}}"#
        let policy = try JSONDecoder().decode(FanPolicy.self, from: Data(sent.utf8))
        for (second, sample) in samples.enumerated() {
            for group in SensorGroup.allCases {
                fans.set(group: group, sample.groups[group])
                fans.set(zone: group, sample.zones[group])
            }
            fans.set(temperature: sample.groups[.cpu])
            fans.set(hottest: sample.groups[.cpu])
            let now = t0.advanced(by: .seconds(second))
            if second == 0 { try await core.setFanPolicy(policy, now: now) } else { await core.updateFans(now: now) }
            let status = await core.coolingStatus()
            guard status.override == nil, let followed = status.hottestTemperature, followed < 85 else { continue }
            let targets = try #require(fans.targets.last)
            #expect(targets.allSatisfy { $0 < Self.fanRange.maximum },
                    "second \(second): full speed at \(followed) °C, airflow \(sample.groups[.airflow] ?? 0) °C")
        }
    }

    @Test func recordingsParse() throws {
        for name in Self.traces {
            let samples = try Self.load(name)
            #expect(samples.allSatisfy { $0.groups[.cpu] != nil && $0.groups[.airflow] != nil }, "\(name)")
        }
    }
}
