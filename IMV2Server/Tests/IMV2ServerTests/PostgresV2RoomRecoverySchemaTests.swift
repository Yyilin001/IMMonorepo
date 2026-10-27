@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import FluentPostgresDriver
import SQLKit
import PostgresNIO
import Testing

@Suite("Room recovery schema retirement", .serialized)
struct PostgresV2RoomRecoverySchemaTests {
    @Test("resource directory readiness requires its exact binding trigger and bounded index",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"] != nil
                   && ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"),
          arguments: ["missing-trigger", "disabled-trigger", "wrong-events", "changed-function",
                      "wrong-search-path", "missing-index", "wrong-index-order", "unfiltered-index"])
    func resourceDirectoryReadinessRejectsDrift(_ fault: String) async throws {
        try await withUserEventDatabase { database, sql, schema in
            try await V2SchemaReadiness.verify(database: database, schema: schema)
            switch fault {
            case "missing-trigger":
                try await sql.raw("DROP TRIGGER message_media_references_room_position ON \(unsafeRaw: schema).message_media_references").run()
            case "disabled-trigger":
                try await sql.raw("ALTER TABLE \(unsafeRaw: schema).message_media_references DISABLE TRIGGER message_media_references_room_position").run()
            case "wrong-events":
                try await sql.raw("DROP TRIGGER message_media_references_room_position ON \(unsafeRaw: schema).message_media_references").run()
                try await sql.raw("CREATE TRIGGER message_media_references_room_position BEFORE INSERT ON \(unsafeRaw: schema).message_media_references FOR EACH ROW EXECUTE FUNCTION \(unsafeRaw: schema).bind_message_media_room_position()").run()
            case "changed-function":
                try await sql.raw("CREATE OR REPLACE FUNCTION \(unsafeRaw: schema).bind_message_media_room_position() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog, \(unsafeRaw: schema) AS 'BEGIN RETURN NEW; END;'").run()
            case "wrong-search-path":
                try await sql.raw("ALTER FUNCTION \(unsafeRaw: schema).bind_message_media_room_position() SET search_path=public").run()
            case "missing-index":
                try await sql.raw("DROP INDEX \(unsafeRaw: schema).message_media_references_room_directory_idx").run()
            case "wrong-index-order":
                try await sql.raw("DROP INDEX \(unsafeRaw: schema).message_media_references_room_directory_idx").run()
                try await sql.raw("CREATE INDEX message_media_references_room_directory_idx ON \(unsafeRaw: schema).message_media_references(room_id,room_sequence,ordinal,media_id) WHERE revoked_at IS NULL").run()
            case "unfiltered-index":
                try await sql.raw("DROP INDEX \(unsafeRaw: schema).message_media_references_room_directory_idx").run()
                try await sql.raw("CREATE INDEX message_media_references_room_directory_idx ON \(unsafeRaw: schema).message_media_references(room_id,room_sequence DESC,ordinal DESC,media_id DESC)").run()
            default: Issue.record("Unknown directory DDL fault"); return
            }
            await #expect(throws: V2SchemaReadinessError.unavailableTable(schema + ".message_media_references[directory-contract]")) {
                try await V2SchemaReadiness.verify(database: database, schema: schema)
            }
        }
    }

    @Test("readiness renders catalog definitions independently of the connection search path")
    func readinessPreservesConnectionSearchPath() async throws {
        try await withUserEventDatabase { _, _, schema in
            let url = try #require(ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"])
            let resources = makeV2DatabaseTestResources()
            do {
                var configuration = try SQLPostgresConfiguration(url: url)
                configuration.searchPath = [schema]
                resources.databases.use(.postgres(configuration: configuration), as: .psql, isDefault: true)
                let database = resources.database(.psql)
                let sql = try #require(database as? any SQLDatabase)
                let before = try #require(try await sql.raw("""
                    SELECT current_setting('search_path') AS path,
                           pg_get_constraintdef(oid) AS definition
                    FROM pg_constraint
                    WHERE conrelid = to_regclass(\(bind: schema + ".room_memberships"))
                      AND conname = 'room_memberships_room_id_fkey'
                    """).first(decoding: SearchPathReadinessRow.self))
                #expect(before.path == schema)
                #expect(before.definition == "FOREIGN KEY (room_id) REFERENCES rooms(room_id)")

                try await V2SchemaReadiness.verify(database: database, schema: schema)

                let after = try #require(try await sql.raw("""
                    SELECT current_setting('search_path') AS path,
                           pg_get_constraintdef(oid) AS definition
                    FROM pg_constraint
                    WHERE conrelid = to_regclass(\(bind: schema + ".room_memberships"))
                      AND conname = 'room_memberships_room_id_fkey'
                    """).first(decoding: SearchPathReadinessRow.self))
                #expect(after.path == schema)
                #expect(after.definition == before.definition)

                try await database.withConnection { pinned in
                    #expect(pinned.inTransaction)
                    let pinnedSQL = try #require(pinned as? any SQLDatabase)
                    try await V2SchemaReadiness.verify(database: pinned, schema: schema)
                    await #expect(throws: V2SchemaReadinessError.unavailableTable(schema + "_missing.schema_contract")) {
                        try await V2SchemaReadiness.verify(database: pinned, schema: schema + "_missing")
                    }
                    let path = try #require(try await pinnedSQL.raw("SELECT current_setting('search_path') AS path")
                        .first(decoding: SearchPathOnlyRow.self)).path
                    #expect(path == schema)
                }
                try await resources.shutdown()
            } catch {
                try? await resources.shutdown()
                throw error
            }
        }
    }

    @Test("readiness rejects retired authorization schema instead of accepting a mixed deployment",
          arguments: ["direct_authorization_intents", "direct_authorization_receipts",
                      "policy_authorization_holders", "policy_authorization_revocations",
                      "policy_authorization_holder_generation", "room_policy_authorization_leases"])
    func rejectsRetiredAuthorizationSchema(name: String) async throws {
        try await withUserEventDatabase { database, sql, schema in
            try await V2SchemaReadiness.verify(database: database, schema: schema)
            if name == "policy_authorization_holder_generation" {
                try await sql.raw("CREATE SEQUENCE \(unsafeRaw: schema).\(unsafeRaw: name)").run()
            } else {
                try await sql.raw("CREATE TABLE \(unsafeRaw: schema).\(unsafeRaw: name) (marker boolean)").run()
            }
            await #expect(throws: V2SchemaReadinessError.unavailableTable(schema + "." + name + ".retired")) {
                try await V2SchemaReadiness.verify(database: database, schema: schema)
            }
        }
    }

    @Test(arguments: [PostgresV2ControlPlaneHousekeepingStore.housekeepingRotationPeriod, Int64.max])
    func housekeepingReadinessRejectsOutOfRangeRotation(rotation: Int64) async throws {
        try await withUserEventDatabase { database, sql, schema in
            try await V2SchemaReadiness.verify(database: database, schema: schema)
            try await sql.raw("UPDATE \(unsafeRaw: schema).control_housekeeping_cursor SET rotation = \(bind: rotation)").run()
            await #expect(throws: V2SchemaReadinessError.unavailableTable(schema + ".control_housekeeping_cursor[rotation]")) {
                try await V2SchemaReadiness.verify(database: database, schema: schema)
            }
            for valid in [Int64(0), PostgresV2ControlPlaneHousekeepingStore.housekeepingRotationPeriod - 1] {
                try await sql.raw("UPDATE \(unsafeRaw: schema).control_housekeeping_cursor SET rotation = \(bind: valid)").run()
                try await V2SchemaReadiness.verify(database: database, schema: schema)
            }
        }
    }

    @Test(arguments: ["state", "decision", "index", "history"])
    func cancellationContractRejectsDrift(_ target: String) async throws {
        try await withUserEventDatabase { database, sql, schema in
            try await V2SchemaReadiness.verify(database: database, schema: schema)
            if target == "history" {
                try await sql.raw("DROP INDEX \(unsafeRaw: schema).group_join_requests_applicant_history_idx").run()
            } else if target == "index" {
                try await sql.raw("DROP INDEX \(unsafeRaw: schema).group_join_requests_invite_id_applicant_user_id_key").run()
                try await sql.raw("CREATE UNIQUE INDEX group_join_requests_invite_id_applicant_user_id_key ON \(unsafeRaw: schema).group_join_requests(invite_id, applicant_user_id)").run()
            } else {
                let constraint = "group_join_requests_" + target + "_check"
                try await sql.raw("ALTER TABLE \(unsafeRaw: schema).group_join_requests DROP CONSTRAINT \(unsafeRaw: constraint)").run()
                try await sql.raw("ALTER TABLE \(unsafeRaw: schema).group_join_requests ADD CONSTRAINT \(unsafeRaw: constraint) CHECK (true)").run()
            }
            await #expect(throws: V2SchemaReadinessError.unavailableTable(schema + ".group_join_requests[cancellation]")) {
                try await V2SchemaReadiness.verify(database: database, schema: schema)
            }
        }
    }

    @Test(arguments: ["messages_visible_membership_idx", "room_events_accepted_membership_idx"])
    func currentSchemaRequiresExactMembershipIndex(index: String) async throws {
        try await withUserEventDatabase { database, sql, schema in
            let table = index == "messages_visible_membership_idx" ? "messages" : "room_events"
            let definition = index == "messages_visible_membership_idx"
                ? "(room_id, accepted_membership_revision, room_sequence DESC) WHERE accepted_event_storage = 'message_row' AND withdrawn_at IS NULL"
                : "(room_id, committed_membership_revision, room_sequence DESC) WHERE event_type = 'message.accepted'"
            try await V2SchemaReadiness.verify(database: database, schema: schema)
            try await sql.raw("DROP INDEX \(unsafeRaw: schema).\(unsafeRaw: index)").run()
            await #expect(throws: V2SchemaReadinessError.unavailableTable(schema + ".rooms[activity-contract]")) {
                try await V2SchemaReadiness.verify(database: database, schema: schema)
            }
            try await sql.raw("CREATE INDEX \(unsafeRaw: index) ON \(unsafeRaw: schema).\(unsafeRaw: table)(room_id)").run()
            await #expect(throws: V2SchemaReadinessError.unavailableTable(schema + ".rooms[activity-contract]")) {
                try await V2SchemaReadiness.verify(database: database, schema: schema)
            }
            try await sql.raw("DROP INDEX \(unsafeRaw: schema).\(unsafeRaw: index)").run()
            try await sql.raw("CREATE INDEX \(unsafeRaw: index) ON \(unsafeRaw: schema).\(unsafeRaw: table) \(unsafeRaw: definition)").run()
            try await V2SchemaReadiness.verify(database: database, schema: schema)
        }
    }

    @Test func currentSchemaRequiresTheExactLatestVisibleIndex() async throws {
        try await withUserEventDatabase { database, sql, schema in
            try await V2SchemaReadiness.verify(database: database, schema: schema)
            try await sql.raw("DROP INDEX \(unsafeRaw: schema).messages_latest_visible_idx").run()
            await #expect(throws: V2SchemaReadinessError.unavailableTable(schema + ".rooms[activity-contract]")) {
                try await V2SchemaReadiness.verify(database: database, schema: schema)
            }
            try await sql.raw("CREATE INDEX messages_latest_visible_idx ON \(unsafeRaw: schema).messages(room_id)").run()
            await #expect(throws: V2SchemaReadinessError.unavailableTable(schema + ".rooms[activity-contract]")) {
                try await V2SchemaReadiness.verify(database: database, schema: schema)
            }
            try await sql.raw("DROP INDEX \(unsafeRaw: schema).messages_latest_visible_idx").run()
            try await sql.raw("""
                CREATE INDEX messages_latest_visible_idx ON \(unsafeRaw: schema).messages
                    (room_id, room_sequence DESC, message_id DESC) WHERE withdrawn_at IS NULL
                """).run()
            try await V2SchemaReadiness.verify(database: database, schema: schema)
        }
    }

    @Test func currentSchemaRejectsRetiredGlobalActivityIndex() async throws {
        try await withUserEventDatabase { database, sql, schema in
            do { try await V2SchemaReadiness.verify(database: database, schema: schema) }
            catch let error as PSQLError {
                Issue.record("schema SQL: \(error.serverInfo?[.message] ?? "unknown")")
                throw error
            }
            try await sql.raw("""
                CREATE INDEX rooms_last_event_at_idx
                ON \(unsafeRaw: schema).rooms(last_event_at DESC, room_id)
                """).run()
            await #expect(throws: V2SchemaReadinessError.unavailableTable(schema + ".rooms[activity-contract]")) {
                try await V2SchemaReadiness.verify(database: database, schema: schema)
            }
            try await sql.raw("DROP INDEX \(unsafeRaw: schema).rooms_last_event_at_idx").run()
            try await V2SchemaReadiness.verify(database: database, schema: schema)
        }
    }
}

private struct SearchPathReadinessRow: Decodable {
    let path: String
    let definition: String
}

private struct SearchPathOnlyRow: Decodable { let path: String }
