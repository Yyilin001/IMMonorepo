@testable import IMV2ServerInfrastructure
import SQLKit
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
