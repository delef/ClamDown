import Foundation

/// The user's own power settings from before ClamDown first switched on. Written once, and put back when the helper is removed.
public struct OriginalSettings: Codable, Equatable, Sendable {
    /// The user's own `SleepDisabled` value. Nil means it was not recorded, so restoring sets it to 0.
    public var sleepDisabled: Bool?
    /// The battery profile's Low Power Mode. Nil means it could not be read, so restoring leaves it alone.
    public var batteryLowPowerMode: Bool?
    /// When the values were read.
    public var recordedAt: Date

    public init(sleepDisabled: Bool?, batteryLowPowerMode: Bool?, recordedAt: Date) {
        self.sleepDisabled = sleepDisabled
        self.batteryLowPowerMode = batteryLowPowerMode
        self.recordedAt = recordedAt
    }
}

public protocol OriginalSettingsStoring: Sendable {
    func load() throws -> OriginalSettings?
    func save(_ settings: OriginalSettings) throws
    func delete() throws
}

/// Root-owned JSON file, with the same rules as `FileSavedStateStore`: the directory is created with mode 0700
/// and the file written atomically with mode 0600.
public struct FileOriginalSettingsStore: OriginalSettingsStoring {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> OriginalSettings? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(OriginalSettings.self, from: Data(contentsOf: url))
    }

    public func save(_ settings: OriginalSettings) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try JSONEncoder().encode(settings).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func delete() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
