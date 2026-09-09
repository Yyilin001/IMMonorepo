import Foundation
import GRDB
@testable import IMV2ClientKit
import IMV2Core
import Testing

struct V2SyncCursorRecoveryBoundsTests {
    @Test(arguments: [Double.infinity, -.infinity])
    func restoredResetExpiryDateBounds(seconds: Double) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-reset-expiry-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "state.sqlite")
        let binding = V2LocalInstallationBinding(value: UUID())
        var store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        do {
            let reset = try V2ClientResetRequired(snapshotID: .init(uuid: UUID()), generation: 2, baseSequence: 10, expiresAt: Date(timeIntervalSince1970: 2_000))
            try await store.beginReset(reset)
            let originalPool = await store.databasePool
            try await originalPool.write { try $0.execute(sql: "UPDATE v2_sync_cursor SET pending_expires_at = ?", arguments: [seconds]) }
            try await store.close()
            store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
            await #expect(throws: V2ClientSyncError.snapshotMismatch) { try await store.cursor() }
            let pool = await store.databasePool
            #expect(try await pool.read { try Double.fetchOne($0, sql: "SELECT pending_expires_at FROM v2_sync_cursor") } == seconds)
            try await pool.write { try $0.execute(sql: "UPDATE v2_sync_cursor SET pending_expires_at = 2000") }
            #expect(try await store.cursor()?.pendingReset == reset)
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test(arguments: [Int64(-1), Int64.min, 0, 1, Int64.max])
    func persistedResetBase(base: Int64) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-cursor-bounds-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "state.sqlite")
        let binding = V2LocalInstallationBinding(value: UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        try await store.beginReset(.init(snapshotID: .init(uuid: UUID()), generation: 2, baseSequence: 1, expiresAt: .distantFuture))
        try await store.close()
        let pool = try DatabasePool(path: url.path)
        try await pool.write { db in
            try db.execute(sql: "UPDATE v2_sync_cursor SET pending_base_sequence = ?", arguments: [base])
        }
        try pool.close()
        let reopened = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        do {
            if base < 0 {
                await #expect(throws: V2ClientSyncError.storageRangeExceeded) { _ = try await reopened.cursor() }
            } else {
                #expect(try await reopened.cursor()?.pendingReset?.baseSequence == UInt64(base))
            }
            try await reopened.close()
        } catch {
            try? await reopened.close()
            throw error
        }
    }
}
