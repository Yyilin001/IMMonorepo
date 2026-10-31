import Foundation
import GRDB
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Room projection stored integers")
struct V2RoomProjectionStorageTests {
    @Test("invalid stored sequence or revision rolls back delivery and can be repaired", arguments:
        ["timeline", "profile", "profile-new"], [1.5, Double(Int64.max)])
    func invalidStoredInteger(scenario: String, value: Double) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "room-storage-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "client.sqlite"),
            installationBinding: .init(value: UUID()))
        let room = RoomID(uuid: UUID()).rawValue
        let actor = UserID(uuid: UUID()).rawValue
        let source = EventID(uuid: UUID())
        let isNew = scenario.hasSuffix("-new")
        let kind: String
        let table: String
        let column: String
        var payload: [String: Any] = ["room_id": room, "server_created_at_ms": 1000]
        switch scenario {
        case "timeline":
            kind = "timeline_activity"; table = "v2_timeline_activity_projections"; column = "timeline_sequence"
            payload["event_type"] = "direct_message_restricted"
        default:
            kind = "room"; table = "v2_room_profile_projections"; column = "membership_revision"
            payload["event_type"] = "room.created"; payload["owner_user_id"] = actor
            payload["title"] = "Integer boundaries"; payload["capacity_class"] = "standard"
            payload["created_at_ms"] = 1000
        }
        payload[column] = 1
        func batch(_ sequence: UInt64, _ source: EventID, _ payload: [String: Any]) throws -> V2ClientSyncBatch {
            try .init(generation: 1, records: [.init(sequence: sequence, sourceEventID: source,
                projectionKind: kind, payload: JSONSerialization.data(withJSONObject: payload))],
                nextSyncToken: .init("room-storage"), receipt: .init("room-storage"), hasMore: false, capabilityProfile: "base")
        }
        _ = try await store.apply(batch(1, source, payload))
        let before = try await store.cursor()
        try await store.databasePool.write { db in
            // Preserve the projection while removing only its separate delivery fixture.
            if !isNew { try db.execute(sql: "DELETE FROM v2_sync_events") }
            try db.execute(sql: "UPDATE \(table) SET \(column) = ?", arguments: [value])
        }
        if isNew { payload[column] = 2 }
        let incoming = try batch(2, isNew ? .init(uuid: UUID()) : source, payload)
        await #expect(throws: V2ClientSyncError.storageRangeExceeded) { try await store.apply(incoming) }
        #expect(try await store.cursor() == before)
        let stored = try await store.databasePool.read { db in
            let raw = try Double.fetchOne(db, sql: "SELECT \(column) FROM \(table)")
            let type = try String.fetchOne(db, sql: "SELECT typeof(\(column)) FROM \(table)")
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_sync_events WHERE sequence = 2")
            return (raw, type, count)
        }
        #expect(stored.0 == value)
        #expect(stored.1 == "real")
        #expect(stored.2 == 0)
        try await store.databasePool.write { try $0.execute(sql: "UPDATE \(table) SET \(column) = 1") }
        _ = try await store.apply(incoming)
        #expect(try await store.cursor()?.appliedSequence == 2)
        let repaired = try await store.databasePool.read { try Int64.fetchOne($0, sql: "SELECT \(column) FROM \(table)") }
        #expect(repaired == (isNew ? 2 : 1))
        try await store.close()
    }

    @Test("room-log moderation integers are checked before snapshot retention and control updates",
          arguments: [false, true], [1.5, Double(Int64.max)])
    func invalidRoomLogInteger(control: Bool, value: Double) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "room-log-storage-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "client.sqlite"),
            installationBinding: .init(value: UUID()))
        let room = RoomID(uuid: UUID()), actor = UserID(uuid: UUID())
        let table = control ? "v2_room_control_projections" : "v2_moderation_projections"
        let source = EventID(uuid: UUID())
        func event(_ sequence: UInt64) throws -> V2ClientGroupEvent {
            var payload: [String: Any] = ["room_id": room.rawValue, "room_sequence": sequence,
                "actor_user_id": actor.rawValue, "server_created_at_ms": 1000,
                "event_type": control ? "room.frozen" : "member.muted"]
            if !control { payload["target_user_id"] = actor.rawValue; payload["mute_until_ms"] = 2000 }
            return try .init(sourceEventID: sequence == 1 ? source : .init(uuid: UUID()),
                roomSequence: sequence, projectionKind: "moderation", payload: JSONSerialization.data(withJSONObject: payload))
        }
        do {
            _ = try await store.applyGroupEventPage(.init(roomID: room, events: [event(1)], nextRoomSequence: 1, hasMore: false))
            try await store.databasePool.write { try $0.execute(sql: "UPDATE \(table) SET room_sequence = ?", arguments: [value]) }
            if control {
                let next = try V2ClientGroupEventPage(roomID: room, events: [event(2)], nextRoomSequence: 2, hasMore: false)
                await #expect(throws: V2ClientSyncError.storageRangeExceeded) { try await store.applyGroupEventPage(next) }
            } else {
                await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await store.moderationActions() }
            }
            #expect(try await store.groupEventCursor(roomID: room) == 1)
            #expect(try await store.cursor() == nil)

            // The personal snapshot supplies membership, never moderation.
            // Its local activation must validate the independently recovered log.
            let item = try V2SnapshotProjectionItem(key: .init(projectionKind: "room", entityKey: room.rawValue),
                sourceEventID: .init(uuid: UUID()), sequence: 1,
                payload: JSONSerialization.data(withJSONObject: ["event_type": "room.created", "room_id": room.rawValue,
                    "title": "Retained", "owner_user_id": actor.rawValue, "membership_revision": 1,
                    "capacity_class": "standard", "created_at_ms": 1000]))
            let page = try V2SnapshotProjectionV3Page(items: [item]), bytes = try V2SnapshotProjectionV3Codec.encode(page)
            let initial = V2SnapshotV3Digest.initial(baseSequence: 10, capabilityProfile: "base")
            let digest = V2SnapshotV3Digest.page(bytes)
            let manifest = try V2ClientSnapshotManifest(reset: .init(snapshotID: .init(uuid: UUID()),
                generation: 2, baseSequence: 10, expiresAt: .distantFuture),
                rootDigest: V2SnapshotV3Digest.next(previous: initial, pageIndex: 0, pageDigest: digest,
                    firstKey: page.firstKey, lastKey: page.lastKey, itemCount: 1),
                pageCount: 1, totalItems: 1, totalBytes: UInt64(bytes.count),
                nextSyncToken: .init("retained"), receipt: .init("retained"), capabilityProfile: "base")
            try await store.beginReset(manifest.reset)
            try await store.beginSnapshotImport(manifest, initialDigest: initial)
            try await store.applySnapshotPage(.init(index: 0, digest: digest, firstKey: page.firstKey,
                lastKey: page.lastKey, itemCount: 1, payload: bytes), for: manifest)
            let before = try await store.cursor()
            await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await store.prepareSnapshotActivation(manifest) }
            #expect(try await store.cursor() == before)
            try await store.databasePool.read { db in
                let sequence = try Double.fetchOne(db, sql: "SELECT room_sequence FROM \(table)")
                let prepared = try Bool.fetchOne(db, sql: "SELECT activation_prepared FROM v2_snapshot_import")
                #expect(sequence == value)
                #expect(prepared == false)
            }
            try await store.databasePool.write { try $0.execute(sql: "UPDATE \(table) SET room_sequence = 1") }
            try await store.prepareSnapshotActivation(manifest)
            try await store.activateAcknowledgedSnapshot(manifest)
            #expect(try await store.cursor()?.generation == 2)
            #expect(try await store.groupEventCursor(roomID: room) == 1)
            _ = try await store.applyGroupEventPage(.init(roomID: room, events: [event(2)], nextRoomSequence: 2, hasMore: false))
            #expect(try await store.groupEventCursor(roomID: room) == 2)
            if control { #expect(try await store.roomControl(roomID: room)?.roomSequence == 2) }
            else { #expect(try await store.moderationActions().map(\.roomSequence).sorted() == [1, 2]) }
            try await store.close()
        } catch { try? await store.close(); throw error }
    }
}
