import Foundation
import Testing
@testable import ClamDownHelperKit

@Suite struct OriginalSettingsStoreTests {
    private func makeStore() -> (FileOriginalSettingsStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clamdown-test-\(UUID().uuidString)")
        return (FileOriginalSettingsStore(url: dir.appendingPathComponent("original.json")), dir)
    }

    private let settings = OriginalSettings(sleepDisabled: true, batteryLowPowerMode: nil,
                                            recordedAt: Date(timeIntervalSince1970: 1_700_000_000))

    @Test func roundTripsAndUses0600() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(settings)
        #expect(try store.load() == settings)
        let file = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("original.json").path)
        #expect(file[.posixPermissions] as? Int == 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: dir.path)
        #expect(folder[.posixPermissions] as? Int == 0o700)
    }

    @Test func loadMissingIsNilAndDeleteIsIdempotent() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try store.load() == nil)
        try store.delete()
        try store.save(settings)
        try store.delete()
        try store.delete()
        #expect(try store.load() == nil)
    }
}
