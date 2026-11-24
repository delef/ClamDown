import Foundation
import Testing
import ClamDownSensors
import ClamDownShared
@testable import ClamDownHelperKit

/// The fan trace runs as root on every user's Mac: it must keep to its size, and what it writes must replay as a
/// sensor recording, which is what makes a complaint a test.
@Suite struct FanTraceFileTests {
    private static func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("clamdown-trace-\(UUID().uuidString)")
    }

    private static func files(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    private static let tick = FanTick(
        reading: HardwareReading(cpuTemperature: 50, hottestCPUTemperature: 60,
                                 fans: [FanReading(rpm: 1350, minimum: 1350, maximum: 5350, index: 0)], lidClosed: true,
                                 groupTemperatures: [.cpu: 60, .battery: 30]),
        followed: 50, outcome: .set)

    /// Writes the trace through a running helper, as the live journal does.
    private final class TraceJournal: HelperJournal, @unchecked Sendable {
        let trace: FanTraceFile
        var errors: [Error] = []
        init(trace: FanTraceFile) { self.trace = trace }
        func change(_ topic: JournalTopic, _ message: String) {}
        func failure(_ topic: JournalTopic, _ message: String) {}
        func record(_ tick: FanTick) {
            do { try trace.append(tick, at: Date()) } catch { errors.append(error) }
        }
    }

    @Test func aTraceTheHelperWritesReplaysAsTheRecordingItCameFrom() async throws {
        let directory = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let samples = try SensorTraceTests.load("m3-pro-desk-burst-and-light-load")
        let policy = FanPolicy(points: StandardCurve.points(start: StandardCurve.defaultStart, full: StandardCurve.defaultFull),
                               onlyWhenLidClosed: true)
        var written: [[Double]] = []
        let journal = TraceJournal(trace: FanTraceFile(directory: directory))
        try await SensorTraceTests.replay(samples, policy: policy, journal: journal) { _, _, _, targets in
            written.append(targets)
        }
        #expect(journal.errors.isEmpty)
        // A run that crosses an hour writes two files; together they hold the run.
        let rows = try Self.files(in: directory).flatMap { name in
            try SensorTraceTests.load(contentsOf: directory.appendingPathComponent(name))
        }
        #expect(rows.count == samples.count)
        for (second, (row, sample)) in zip(rows, samples).enumerated() {
            #expect(row.groups == sample.groups, "second \(second)")
            #expect(row.zones == sample.zones, "second \(second)")
        }
        let lines = try Self.files(in: directory).flatMap { name in
            try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
                .split(whereSeparator: \.isNewline).dropFirst()
        }
        let header = FanTraceFile.header
        let target = try #require(header.firstIndex(of: "target")), outcome = try #require(header.firstIndex(of: "outcome"))
        for (second, line) in lines.enumerated() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            #expect(fields[outcome] == "set", "second \(second)")
            #expect(fields[target] == written[second].map { String(format: "%.0f", $0) }.joined(separator: " "),
                    "second \(second)")
        }
    }

    @Test func keepsOnlyTheLastDay() throws {
        let directory = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let trace = FanTraceFile(directory: directory, keep: .seconds(24 * 3600))
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for hour in 0..<30 {
            try trace.append(Self.tick, at: start.addingTimeInterval(Double(hour) * 3600))
        }
        let names = try Self.files(in: directory)
        // The hour now and the 24 before it.
        #expect(names.count == 25)
        #expect(names.first == FanTraceFile.fileName(for: start.addingTimeInterval(5 * 3600)))
    }

    @Test func anHourWrittenByAnotherVersionGoesOnInAFileOfItsOwn() throws {
        let directory = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        func put(_ name: String, _ text: String) throws {
            try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let older = "timestamp,cpu\n2027-01-15T09:00:00+01:00,60.0\n"
        try put(FanTraceFile.fileName(for: time), older)
        // Second files of the oldest hour kept and of the hour before it.
        let kept = FanTraceFile.fileName(for: time.addingTimeInterval(-24 * 3600), part: 2)
        try put(kept, older)
        try put(FanTraceFile.fileName(for: time.addingTimeInterval(-25 * 3600), part: 2), older)

        try FanTraceFile(directory: directory).append(Self.tick, at: time)

        let current = FanTraceFile.fileName(for: time, part: 2)
        #expect(try Self.files(in: directory) == [kept, FanTraceFile.fileName(for: time), current].sorted())
        #expect(try String(contentsOf: directory.appendingPathComponent(FanTraceFile.fileName(for: time)),
                           encoding: .utf8) == older)
        let rows = try SensorTraceTests.load(contentsOf: directory.appendingPathComponent(current))
        #expect(rows.map(\.groups) == [Self.tick.groups])
    }

    @Test func anHourStopsGrowingAtItsLimit() throws {
        let directory = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let trace = FanTraceFile(directory: directory, maxFileBytes: 1_000)
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        var refusals: [String] = []
        for second in 0..<100 {
            do { try trace.append(Self.tick, at: time.addingTimeInterval(Double(second))) } catch {
                refusals.append("\(error)")
            }
        }
        // Said once, not on every tick of the hour.
        #expect(refusals == ["\(FanTraceFile.fileName(for: time)) is full; the rest of this hour is not written"])
        let name = try #require(try Self.files(in: directory).first)
        let size = try #require(try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent(name).path)[.size] as? Int)
        let row = FanTraceFile.row(Self.tick, at: time).utf8.count + 1
        #expect(size < 1_000 + row)
    }
}
