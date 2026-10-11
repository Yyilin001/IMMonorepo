@testable import IMV2ServerInfrastructure
import SQLKit
import Foundation
import PostgresNIO
import Testing

extension PostgresV2RoomRecoverySchemaTests {
    @Test("retained edit audiences require immutable facts and the exact capture contract",
          arguments: ["table", "key", "nullable", "index", "capture", "predicate", "capture-body", "immutable", "immutable-body"])
    func messageEditVisibilityReadinessRejectsDrift(target: String) async throws {
        try await withUserEventDatabase { database, sql, schema in
            try await V2SchemaReadiness.verify(database: database, schema: schema)
            switch target {
            case "table":
                try await sql.raw("DROP TABLE \(unsafeRaw: schema).message_edit_visibility").run()
            case "key":
                try await sql.raw("ALTER TABLE \(unsafeRaw: schema).message_edit_visibility DROP CONSTRAINT message_edit_visibility_pkey").run()
            case "nullable":
                try await sql.raw("ALTER TABLE \(unsafeRaw: schema).message_edit_visibility ALTER COLUMN committed_membership_revision DROP NOT NULL").run()
            case "index":
                try await sql.raw("DROP INDEX \(unsafeRaw: schema).message_edit_visibility_latest_idx").run()
            case "capture", "predicate":
                try await sql.raw("DROP TRIGGER room_events_capture_message_edit_visibility ON \(unsafeRaw: schema).room_events").run()
                if target == "predicate" {
                    try await sql.raw("""
                        CREATE TRIGGER room_events_capture_message_edit_visibility AFTER INSERT
                        ON \(unsafeRaw: schema).room_events FOR EACH ROW WHEN (NEW.event_type = 'message.accepted')
                        EXECUTE FUNCTION \(unsafeRaw: schema).capture_message_edit_visibility()
                        """).run()
                }
            case "capture-body":
                try await sql.raw("""
                    CREATE OR REPLACE FUNCTION \(unsafeRaw: schema).capture_message_edit_visibility()
                    RETURNS trigger LANGUAGE plpgsql VOLATILE AS $$ BEGIN RETURN NEW; END; $$
                    """).run()
            case "immutable":
                try await sql.raw("DROP TRIGGER message_edit_visibility_immutable ON \(unsafeRaw: schema).message_edit_visibility").run()
            default:
                try await sql.raw("""
                    CREATE OR REPLACE FUNCTION \(unsafeRaw: schema).reject_message_edit_visibility_mutation()
                    RETURNS trigger LANGUAGE plpgsql VOLATILE AS $$ BEGIN RETURN OLD; END; $$
                    """).run()
            }
            let name = target == "table" ? schema + ".message_edit_visibility" : schema + ".message_edit_visibility.retained_audience"
            await #expect(throws: V2SchemaReadinessError.unavailableTable(name)) {
                try await V2SchemaReadiness.verify(database: database, schema: schema)
            }
        }
    }
}

extension PostgresV2RoomRecoverySchemaTests {
    @Test("Malformed edit events cannot commit without audience evidence",
          arguments: ["missing", "invalid-id", "missing-room", "wrong-room", "invalid-revision", "revision-overflow", "initial-revision"])
    func editCaptureRejectsMalformedPayload(kind: String) async throws {
        try await withUserEventDatabase { database, sql, schema in
            try await V2SchemaReadiness.verify(database: database, schema: schema)
            let room = UUID(), message = UUID()
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).rooms(room_id,room_shard_id,capacity_profile_id) VALUES(\(bind: room),'room-a','standard')").run()
            var payload: [String: Any] = ["message_id": message.uuidString, "room_id": room.uuidString, "message_revision": 2]
            switch kind {
            case "missing": payload.removeValue(forKey: "message_id")
            case "invalid-id": payload["message_id"] = "invalid"
            case "missing-room": payload.removeValue(forKey: "room_id")
            case "wrong-room": payload["room_id"] = UUID().uuidString
            case "invalid-revision": payload["message_revision"] = "invalid"
            case "revision-overflow": payload["message_revision"] = "9223372036854775808"
            default: payload["message_revision"] = 1
            }
            let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
            do {
                try await sql.raw("INSERT INTO \(unsafeRaw: schema).room_events(event_id,room_id,room_sequence,event_type,payload,committed_membership_revision,created_at) VALUES(gen_random_uuid(),\(bind: room),1,'message.edited',\(bind: json)::jsonb,0,clock_timestamp())").run()
                Issue.record("Malformed edit event committed")
            } catch let error as PSQLError {
                #expect(error.serverInfo?[.sqlState] == "23514")
            }
            #expect(try await sql.raw("SELECT count(*) AS value FROM \(unsafeRaw: schema).room_events").first(decoding: EditCaptureCount.self)?.value == 0)
            #expect(try await sql.raw("SELECT count(*) AS value FROM \(unsafeRaw: schema).message_edit_visibility").first(decoding: EditCaptureCount.self)?.value == 0)
        }
    }
}

private struct EditCaptureCount: Decodable { let value: Int64 }
