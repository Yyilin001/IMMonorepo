import Foundation
import GRDB
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Room projection stored integers")
struct V2RoomProjectionStorageTests {
    @Test("invalid stored sequence or revision rolls back delivery and can be repaired", arguments:
        ["timeline", "moderation", "control", "control-new", "profile", "profile-new"], [1.5, Double(Int64.max)])
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
        case "moderation":
            kind = "moderation"; table = "v2_moderation_projections"; column = "room_sequence"
            payload["event_type"] = "member.muted"; payload["actor_user_id"] = actor
            payload["target_user_id"] = UserID(uuid: UUID()).rawValue; payload["mute_until_ms"] = 2000
        case "control", "control-new":
            kind = "moderation"; table = "v2_room_control_projections"; column = "room_sequence"
            payload["event_type"] = "room.frozen"; payload["actor_user_id"] = actor
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
        if scenario == "moderation" {
            await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await store.moderationActions() }
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
        if scenario == "moderation" { #expect(try await store.moderationActions().first?.roomSequence == 1) }
        try await store.close()
    }
}
