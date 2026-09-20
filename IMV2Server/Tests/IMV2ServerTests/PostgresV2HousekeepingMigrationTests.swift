import Foundation
import Fluent
import FluentPostgresDriver
import IMV2Core
@testable import IMV2Server
import SQLKit
import Testing
import Vapor

struct PostgresV2HousekeepingMigrationTests {
    @Test func roomReceiptsAndReviewCleanupRespectMigration() async throws {
        guard let url = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let app = try await Application.make(.testing)
        var ownsSchema = false
        do {
            app.databases.use(try .postgres(url: url, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
            let database = app.db(.psql)
            let sql = try #require(database as? any SQLDatabase)
            struct Exists: Decodable { let exists: Bool }
            struct Value: Decodable { let value: String }
            guard try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: Exists.self)?.exists == false else { throw CancellationError() }
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let source = try String(contentsOf: root.appending(path: "IMV2/sql/schema.sql"), encoding: .utf8)
            let executable = source.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }.joined(separator: "\n")
            ownsSchema = true
            for statement in postgresStatements(in: executable) where !statement.isEmpty && statement != "BEGIN" && statement != "COMMIT" {
                try await sql.raw("\(unsafeRaw: statement)").run()
            }
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let retention = V2IdempotencyPolicy.minimumServerRetention
            let old = now.addingTimeInterval(-retention - 86_400)
            let actor = UUID(), frozen = UUID(), live = UUID()
            try await sql.raw("""
                INSERT INTO im_v2.public_user_profiles(user_id, public_handle, display_name, created_at, updated_at)
                VALUES (\(bind: actor), 'cleanup_actor', 'Cleanup actor', \(bind: old), \(bind: old))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.special_accounts(account_user_id, stable_key, account_kind,
                    allows_customer_messages, created_at, updated_at)
                VALUES (\(bind: actor), 'cleanup_system', 'system', false, \(bind: old), \(bind: old))
                """).run()
            // Values below are fixed test SQL; identities and dates stay bound.
            let fixtures: [(table: String, actorColumn: String, dateColumn: String, columns: String, values: String)] = [
                ("direct_room_operations", "actor_user_id", "created_at", "target_user_id", "gen_random_uuid()"),
                ("room_membership_operations", "actor_user_id", "created_at", "target_user_id, action, expected_membership_revision, resulting_membership_revision, room_sequence, event_id", "gen_random_uuid(), 'add', 1, 2, 1, gen_random_uuid()"),
                ("message_withdrawal_operations", "actor_user_id", "created_at", "message_id, expected_message_revision, resulting_message_revision, room_sequence, event_id", "message.message_id, 1, 2, 1, gen_random_uuid()"),
                ("moderation_operations", "actor_user_id", "created_at", "action, reason_code, room_sequence, event_id", "'freeze_room', 'test', 1, gen_random_uuid()"),
                ("message_edit_operations", "actor_user_id", "created_at", "message_id, expected_message_revision, text_body, resulting_message_revision, room_sequence, event_id", "message.message_id, 1, 'edited', 2, 1, gen_random_uuid()"),
                ("read_receipt_operations", "user_id", "recorded_at", "requested_room_sequence, resulting_room_sequence", "1, 1"),
                ("message_reaction_operations", "actor_user_id", "created_at", "message_id, reaction, action, room_sequence, event_id", "message.message_id, 'like', 'add', 1, gen_random_uuid()"),
                ("group_room_operations", "actor_user_id", "created_at", "title, initial_member_user_ids, initial_member_count", "'Test', ARRAY[]::uuid[], 1"),
                ("room_pinned_message_operations", "actor_user_id", "created_at", "message_id, is_pinned, room_sequence, event_id", "message.message_id, true, 1, gen_random_uuid()"),
                ("group_announcement_operations", "actor_user_id", "created_at", "body, expected_revision, resulting_revision, room_sequence, event_id", "'Test', 0, 1, 1, gen_random_uuid()"),
                ("group_permission_operations", "actor_user_id", "created_at", "expected_revision, resulting_revision, role, permissions, room_sequence, event_id", "1, 2, 'member', '{}'::jsonb, 1, gen_random_uuid()"),
                ("group_role_operations", "actor_user_id", "created_at", "target_user_id, role, expected_membership_revision, resulting_membership_revision, room_sequence, event_id", "gen_random_uuid(), 'admin', 1, 2, 1, gen_random_uuid()"),
                ("special_account_message_operations", "account_user_id", "created_at", "request_fingerprint", "'0123456789abcdef'"),
                ("room_member_nickname_operations", "actor_user_id", "created_at", "result_revision", "1")
            ]
            for room in [frozen, live] {
                try await sql.raw("""
                    INSERT INTO im_v2.rooms(room_id, room_kind, room_shard_id, capacity_profile_id, created_at)
                    VALUES (\(bind: room), 'group', 'room-a', 'standard', \(bind: old))
                    """).run()
                try await sql.raw("""
                    INSERT INTO im_v2.messages(message_id, room_id, room_sequence, sender_user_id,
                        client_message_id, text_body, created_at, timeline_sequence)
                    VALUES (\(bind: UUID()), \(bind: room), 1, \(bind: actor), \(bind: UUID()), 'test', \(bind: old), 1)
                    """).run()
                for fixture in fixtures {
                    try await sql.raw("""
                        INSERT INTO im_v2.\(unsafeRaw: fixture.table)
                            (\(unsafeRaw: fixture.actorColumn), operation_id, room_id,
                             \(unsafeRaw: fixture.dateColumn), \(unsafeRaw: fixture.columns))
                        SELECT \(bind: actor), \(bind: UUID()), \(bind: room), \(bind: old), \(unsafeRaw: fixture.values)
                        FROM im_v2.messages AS message WHERE message.room_id = \(bind: room)
                        """).run()
                }
                try await sql.raw("""
                    INSERT INTO im_v2.content_review_jobs(message_id, room_id, expected_content_revision,
                        state, created_at, completed_at)
                    SELECT message_id, room_id, 1, 'completed', \(bind: old), \(bind: old)
                    FROM im_v2.messages WHERE room_id = \(bind: room)
                    """).run()
            }
            try await sql.raw("""
                INSERT INTO im_v2.moderation_audit_entries
                    (actor_user_id, operation_id, room_id, action, reason_code, occurred_at, retain_until)
                SELECT actor_user_id, operation_id, room_id, action, reason_code, created_at, \(bind: old)
                FROM im_v2.moderation_operations
                """).run()
            // User-owned room preferences must remain independently collectible.
            try await sql.raw("""
                INSERT INTO im_v2.user_room_preference_operations
                    (actor_user_id, operation_id, room_id, pinned_at, updated_at)
                VALUES (\(bind: actor), \(bind: UUID()), \(bind: frozen), \(bind: old), \(bind: old))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_owner_routes(room_id, room_shard_id, route_epoch, created_at, updated_at)
                VALUES (\(bind: frozen), 'room-a', 0, \(bind: now), \(bind: now))
                """).run()
            let control = PostgresV2RoomOwnerMigrationPreparationStore(database: database, registeredShardIDs: ["room-a", "room-b"])
            let request = try V2RoomOwnerMigrationPreparation(migrationID: UUID(), roomID: .init(uuid: frozen),
                source: .init(shardID: "room-a", epoch: 0), targetShardID: "room-b")
            _ = try await control.prepare(request, now: now)
            let freezing = try await control.beginFreezing(request, now: now)
            try await PostgresV2RoomMigrationWriteFence(database: database).install(for: freezing)
            let tables = fixtures.map(\.table) + ["content_review_jobs", "moderation_audit_entries"]
            func snapshot(room: UUID) async throws -> [String] {
                var result: [String] = []
                for table in tables {
                    let rows = try await sql.raw("""
                        SELECT row_to_json(target)::text AS value FROM im_v2.\(unsafeRaw: table) AS target
                        WHERE room_id = \(bind: room) ORDER BY row_to_json(target)::text
                        """).all(decoding: Value.self)
                    result.append(contentsOf: rows.map(\.value))
                }
                return result
            }
            let frozenBefore = try await snapshot(room: frozen)
            let liveBefore = try await snapshot(room: live)
            #expect(frozenBefore.count == 16 && liveBefore.count == 16)
            try await database.transaction { holder in
                let holderSQL = try #require(holder as? any SQLDatabase)
                try await holderSQL.raw("SELECT room_id FROM im_v2.rooms WHERE room_id = \(bind: live) FOR UPDATE").run()
                try await database.transaction { contender in
                    let contenderSQL = try #require(contender as? any SQLDatabase)
                    try await contenderSQL.raw("SET LOCAL lock_timeout = '2s'").run()
                    let removedAudit = try await PostgresV2ModerationAuditRetentionStore(database: contender)
                        .deleteExpiredAuditEntries(now: now, limit: 10)
                    #expect(removedAudit == 0)
                    let report = try await PostgresV2ControlPlaneHousekeepingStore(database: contender)
                        .purgeTerminal(now: now, retention: 60, idempotencyRetention: retention, limit: 1_024)
                    #expect(report.deletedRows == 1 && report.purgedIdempotencyRows == 1)
                }
            }
            #expect(try await snapshot(room: live) == liveBefore)
            #expect(try await snapshot(room: frozen) == frozenBefore)
            let store = PostgresV2ControlPlaneHousekeepingStore(database: database)
            // Audit remains authoritative evidence for the moderation receipt:
            // other live rows can expire first, but that receipt must remain.
            let report = try await store.purgeTerminal(now: now, retention: 60, idempotencyRetention: retention, limit: 1_024)
            #expect(report.deletedRows == 14 && report.purgedIdempotencyRows == 13)
            #expect(try await snapshot(room: live).count == 2)
            let removedAudit = try await PostgresV2ModerationAuditRetentionStore(database: database)
                .deleteExpiredAuditEntries(now: now, limit: 1)
            #expect(removedAudit == 1)
            let afterAudit = try await store.purgeTerminal(now: now, retention: 60, idempotencyRetention: retention, limit: 1_024)
            #expect(afterAudit.deletedRows == 1 && afterAudit.purgedIdempotencyRows == 1)
            #expect(try await snapshot(room: live).isEmpty)
            #expect(try await snapshot(room: frozen) == frozenBefore)
            let repeated = try await PostgresV2ControlPlaneHousekeepingStore(database: database)
                .purgeTerminal(now: now, retention: 60, idempotencyRetention: retention, limit: 1_024)
            #expect(!repeated.didWork)
            let repeatedAudit = try await PostgresV2ModerationAuditRetentionStore(database: database)
                .deleteExpiredAuditEntries(now: now, limit: 10)
            #expect(repeatedAudit == 0)
            #expect(try await snapshot(room: frozen) == frozenBefore)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
        } catch {
            if ownsSchema, let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
