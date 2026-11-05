import Foundation
import GRDB
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Durable account room heads")
struct V2AccountRoomHeadTests {
    @Test("personal cursor and recovery responsibility roll back together; stale heads do not rewind work")
    func incrementalAtomicityAndOrdering() async throws {
        try await withStore { store, user in
            let room = RoomID(uuid: UUID())
            let scope = try await store.beginRoomRecoveryScan(userID: user)
            let newer = try record(1, room, 9, 2)
            let invalid = try V2ClientSyncRecord(sequence: 2, sourceEventID: .init(uuid: UUID()),
                projectionKind: "room_head", payload: Data("{\"room_id\":\"invalid\",\"room_sequence\":0,\"membership_revision\":0}".utf8))
            await #expect(throws: (any Error).self) { _ = try await store.apply(batch([newer, invalid])) }
            #expect(try await store.cursor() == nil)
            #expect(try await store.roomRecoveryWork(scope: scope, limit: 5, oldestFirst: true, now: .now).isEmpty)
            _ = try await store.apply(batch([newer]))
            let first = try #require(try await store.roomRecoveryWork(scope: scope, limit: 5, oldestFirst: true, now: .now).first)
            #expect(first.targetHead == 9 && first.requiresState)
            #expect(try await store.groupEventAccess(roomID: room) == nil)
            #expect(try await store.groupEventCursor(roomID: room) == 0)
            _ = try await store.apply(batch([record(2, room, 5, 1)]))
            #expect(try await store.roomRecoveryWork(scope: scope, limit: 5, oldestFirst: true, now: .now).first?.requestRevision == first.requestRevision)
            #expect(try await store.cursor()?.appliedSequence == 2)
            await #expect(throws: V2ClientProjectionError.invalidMessagePayload) {
                _ = try await store.apply(batch([record(3, room, 9, 3)]))
            }
            #expect(try await store.cursor()?.appliedSequence == 2)
            let revoke = try V2ClientSyncRecord(sequence: 3, sourceEventID: .init(uuid: UUID()), projectionKind: "membership",
                payload: JSONSerialization.data(withJSONObject: ["event_type": "membership_changed", "room_id": room.rawValue,
                    "membership_revision": 3, "target_user_id": user.rawValue, "action": "remove", "title": "Removed",
                    "owner_user_id": user.rawValue, "capacity_class": "standard", "created_at_ms": 1000, "server_created_at_ms": 2000]))
            _ = try await store.apply(batch([revoke, record(4, room, 10, 2)]))
            #expect(try await store.roomRecoveryWork(scope: scope, limit: 5, oldestFirst: true, now: .now).isEmpty)
            #expect(try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM v2_account_room_heads") } == 0)
            #expect(try await store.cursor()?.appliedSequence == 4)
        }
    }

    @Test("snapshot heads stay in shadows until activation and request bounded reconciliation")
    func snapshotVisibility() async throws {
        try await withStore { store, user in
            let room = RoomID(uuid: UUID()), scope = try await store.beginRoomRecoveryScan(userID: user)
            try await store.commitRoomRecoveryDirectoryPage(.init(rooms: [], nextCursor: nil, topologyGeneration: "one"),
                expectedCursor: nil, request: try await store.roomRecoveryScan(scope: scope), now: .now)
            let reset = try V2ClientResetRequired(snapshotID: .init(uuid: UUID()), generation: 2, baseSequence: 10, expiresAt: .distantFuture)
            let item = try V2SnapshotProjectionItem(key: .init(projectionKind: "room_head", entityKey: room.rawValue),
                sourceEventID: .init(uuid: UUID()), sequence: 10,
                payload: JSONEncoder().encode(V2AccountRoomHead(roomID: room, roomSequence: 40, membershipRevision: 2)))
            let fixture = try makeSnapshotFixture(reset: reset, pages: [.init(items: [item])])
            try await store.beginReset(reset)
            try await store.beginSnapshotImport(fixture.manifest, initialDigest: V2SnapshotV3Digest.initial(baseSequence: 10, capabilityProfile: "base"))
            try await store.applySnapshotPage(fixture.pages[0], for: fixture.manifest)
            #expect(try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM v2_account_room_heads") } == 0)
            #expect(try await store.roomRecoveryWork(scope: scope, limit: 5, oldestFirst: true, now: .now).isEmpty)
            try await store.prepareSnapshotActivation(fixture.manifest)
            try await store.activateAcknowledgedSnapshot(fixture.manifest)
            #expect(try await store.cursor()?.generation == 2)
            #expect(try await !store.roomRecoveryScan(scope: scope).directoryComplete)
            #expect(try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT room_sequence FROM v2_account_room_heads") } == 40)
            #expect(try await store.groupEventAccess(roomID: room) == nil)
        }
    }

    @Test("stored non-integer heads cannot advance a durable account cursor", arguments: ["room_sequence", "membership_revision"])
    func corruptHeadStorage(column: String) async throws {
        try await withStore { store, _ in
            let room = RoomID(uuid: UUID())
            _ = try await store.apply(batch([record(1, room, 9, 2)]))
            try await store.databasePool.write { db in
                try db.execute(sql: "UPDATE v2_account_room_heads SET \(column) = 1.5")
            }
            await #expect(throws: V2ClientSyncError.storageRangeExceeded) {
                _ = try await store.apply(batch([record(2, room, 10, 3)]))
            }
            #expect(try await store.cursor()?.appliedSequence == 1)
        }
    }

    private func record(_ sequence: UInt64, _ room: RoomID, _ head: UInt64, _ revision: UInt64) throws -> V2ClientSyncRecord {
        try .init(sequence: sequence, sourceEventID: .init(uuid: UUID()), projectionKind: "room_head",
            payload: JSONEncoder().encode(V2AccountRoomHead(roomID: room, roomSequence: head, membershipRevision: revision)))
    }
    private func batch(_ records: [V2ClientSyncRecord]) throws -> V2ClientSyncBatch {
        try .init(generation: 1, records: records, nextSyncToken: .init("next"), receipt: .init("receipt"), hasMore: false, capabilityProfile: "base")
    }
    private func withStore(_ body: (GRDBV2LocalSyncStore, UserID) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "account-head-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UserID(uuid: UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "client.sqlite"),
            installationBinding: .init(value: UUID()), userID: user)
        do { try await body(store, user); try await store.close() }
        catch { try? await store.close(); throw error }
    }
}

extension V2AccountRoomHeadTests {
    @Test("obsolete local account layouts fail at open without altering retained data", arguments: [false, true])
    func rejectsObsoleteSchema(altered: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "account-head-schema-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "client.sqlite"), user = UserID(uuid: UUID())
        let binding = V2LocalInstallationBinding(value: UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: user)
        try await store.databasePool.write {
            try $0.execute(sql: altered ? "ALTER TABLE v2_account_room_heads ADD COLUMN incompatible INTEGER" : "DROP TABLE v2_account_room_heads")
            try $0.execute(sql: "CREATE TABLE retained_pending_command(value TEXT); INSERT INTO retained_pending_command VALUES('pending')")
        }
        try await store.close()
        #expect(throws: V2ClientLocalStorageError.unsupportedAccountRecoverySchema) {
            _ = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: user)
        }
        #expect(throws: V2ClientLocalStorageError.unsupportedAccountRecoverySchema) {
            _ = try GRDBV2LocalSyncStore(localReadOnlyDatabaseURL: url, installationBinding: binding, userID: user)
        }
        let inspection = try DatabaseQueue(path: url.path)
        defer { try? inspection.close() }
        #expect(try await inspection.read { try String.fetchOne($0, sql: "SELECT value FROM retained_pending_command") } == "pending")
    }
}
