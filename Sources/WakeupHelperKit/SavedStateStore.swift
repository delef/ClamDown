import Foundation

/// What the helper must put back when it switches the mode off.
public struct SavedState: Codable, Equatable, Sendable {
    /// The battery profile's Low Power Mode before Wakeup changed it.
    public var batteryLowPowerMode: Bool

    public init(batteryLowPowerMode: Bool) {
        self.batteryLowPowerMode = batteryLowPowerMode
    }
}

public protocol SavedStateStoring: Sendable {
    func load() throws -> SavedState?
    func save(_ state: SavedState) throws
    func clear() throws
}

/// Root-owned JSON file. The directory is created with mode 0700 and the file written atomically with mode 0600.
public struct FileSavedStateStore: SavedStateStoring {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> SavedState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: url))
    }

    public func save(_ state: SavedState) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
