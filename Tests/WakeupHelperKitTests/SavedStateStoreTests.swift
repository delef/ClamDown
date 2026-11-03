import Foundation
import Testing
@testable import WakeupHelperKit

@Suite struct SavedStateStoreTests {
    private func makeStore() -> (FileSavedStateStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wakeup-test-\(UUID().uuidString)")
        return (FileSavedStateStore(url: dir.appendingPathComponent("state.json")), dir)
    }

    @Test func roundTripsAndUses0600() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(SavedState(batteryLowPowerMode: true))
        #expect(try store.load() == SavedState(batteryLowPowerMode: true))
        let file = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("state.json").path)
        #expect(file[.posixPermissions] as? Int == 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: dir.path)
        #expect(folder[.posixPermissions] as? Int == 0o700)
    }

    @Test func loadMissingIsNilAndClearIsIdempotent() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try store.load() == nil)
        try store.clear()
        try store.save(SavedState(batteryLowPowerMode: false))
        try store.clear()
        try store.clear()
        #expect(try store.load() == nil)
    }
}
