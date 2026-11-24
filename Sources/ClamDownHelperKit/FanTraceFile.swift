import Foundation
import ClamDownShared

/// The fan ticks of the last day as CSV, one file per hour (`fans-<UTC hour>.csv`), so what the fans did and why can
/// be looked at after the fact. Its columns start as a sensor recording's do (`timestamp`, the groups, `zone.<group>`),
/// so a trace replays in `SensorTraceTests` as it is.
///
/// Each tick is written at once, without a buffer: a crash then loses nothing, and one short line every few seconds
/// costs the disk nothing that matters. Files older than `keep` are deleted when a new hour starts, and an hour stops
/// growing at `maxFileBytes`, so a root process can never fill the disk with it.
public final class FanTraceFile: @unchecked Sendable {
    public enum Problem: Error, CustomStringConvertible {
        /// The hour reached `maxFileBytes`; its later ticks are not written. Thrown once per hour.
        case hourFull(String)
        /// The tick was written, but old files could not be deleted. The next hour tries again.
        case pruneFailed(Error)

        public var description: String {
            switch self {
            case .hourFull(let name): "\(name) is full; the rest of this hour is not written"
            case .pruneFailed(let error): "could not delete old trace files: \(error)"
            }
        }
    }

    public static let defaultKeep: Duration = .seconds(24 * 3600)
    /// About ten times what an hour of three-second ticks takes.
    public static let defaultMaxFileBytes: UInt64 = 2_000_000

    private let directory: URL
    private let keep: Duration
    private let maxFileBytes: UInt64
    private let lock = NSLock()
    private var handle: FileHandle?
    private var hour: String?
    private var hourFull = false

    public init(directory: URL, keep: Duration = defaultKeep, maxFileBytes: UInt64 = defaultMaxFileBytes) {
        self.directory = directory
        self.keep = keep
        self.maxFileBytes = maxFileBytes
    }

    deinit {
        try? handle?.close()
    }

    /// The column names, in order.
    public static let header: [String] = ["timestamp"]
        + SensorGroup.allCases.map(\.rawValue)
        + SensorGroup.allCases.map { "zone.\($0.rawValue)" }
        + ["core.hottest", "cpu.average", "lid", "followed", "percent", "override", "rpm", "target", "outcome"]

    /// Writes one tick taken at `time`. Throws when the file cannot be opened or written; the next tick tries again.
    public func append(_ tick: FanTick, at time: Date) throws {
        lock.lock()
        defer { lock.unlock() }
        let name = Self.fileName(for: time)
        var pruneError: Error?
        if name != hour {
            try? handle?.close()
            handle = nil
            hour = nil
            handle = try open(name)
            hour = name
            hourFull = false
            do { try prune(before: time.addingTimeInterval(-Double(keep.components.seconds))) } catch { pruneError = error }
        }
        if let handle, try handle.offset() < maxFileBytes {
            try handle.write(contentsOf: Data((Self.row(tick, at: time) + "\n").utf8))
        } else if !hourFull {
            hourFull = true
            throw Problem.hourFull(name)
        }
        // The tick is written first: old files left over are no reason to lose it. The next hour prunes again.
        if let pruneError { throw Problem.pruneFailed(pruneError) }
    }

    /// The file for the hour of `time`, created with the header when new.
    private func open(_ name: String) throws -> FileHandle {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        let url = directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            let header = Data((Self.header.joined(separator: ",") + "\n").utf8)
            guard FileManager.default.createFile(atPath: url.path, contents: header,
                                                 attributes: [.posixPermissions: 0o644]) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }

    /// Deletes the trace files of hours before `cutoff`. Names sort by time, so the name decides.
    private func prune(before cutoff: Date) throws {
        let oldest = Self.fileName(for: cutoff)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        for name in names where name.hasPrefix("fans-") && name.hasSuffix(".csv") && name < oldest {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    static func fileName(for time: Date) -> String {
        "fans-" + hourFormat.string(from: time) + "Z.csv"
    }

    static func row(_ tick: FanTick, at time: Date) -> String {
        let fields: [String] = [time.formatted(timestampFormat)]
            + SensorGroup.allCases.map { number(tick.groups[$0]) }
            + SensorGroup.allCases.map { number(tick.zones[$0]) }
            + [number(tick.hottestCore), number(tick.cpuAverage), tick.lidClosed.map { $0 ? "closed" : "open" } ?? "",
               number(tick.followed), number(tick.percent), tick.override?.rawValue ?? "",
               list(tick.fanRPM), tick.targets.map(list) ?? "", tick.outcome.rawValue]
        return fields.joined(separator: ",")
    }

    private static func number(_ value: Double?) -> String {
        value.map { String(format: "%.1f", $0) } ?? ""
    }

    /// Speeds in rpm, one per fan, in fan order: a Mac has one fan or two, so they share a column.
    private static func list(_ values: [Double]) -> String {
        values.map { String(format: "%.0f", $0) }.joined(separator: " ")
    }

    private static let hourFormat: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyy-MM-dd'T'HH"
        return format
    }()

    /// Local time with its offset, as the sensor recordings have it.
    private static let timestampFormat = Date.ISO8601FormatStyle(timeZoneSeparator: .colon, timeZone: .current)
}
