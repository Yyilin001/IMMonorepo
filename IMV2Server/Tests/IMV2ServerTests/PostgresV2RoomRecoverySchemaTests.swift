import Foundation
@testable import IMV2Server
import SQLKit
import PostgresNIO
import Testing

@Suite("Room recovery schema retirement", .serialized)
struct PostgresV2RoomRecoverySchemaTests {
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
