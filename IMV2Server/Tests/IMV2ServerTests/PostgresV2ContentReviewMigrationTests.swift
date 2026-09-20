import Foundation
import Fluent
import FluentPostgresDriver
import IMV2Core
@testable import IMV2Server
import SQLKit
import Testing
import Vapor

struct PostgresV2ContentReviewMigrationTests {
    @Test func reviewJobsStopAtMigrationFence() async throws {
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
            let frozen = UUID(), live = UUID(), actor = UUID()
            for room in [frozen, live] {
                try await sql.raw("""
                    INSERT INTO im_v2.rooms(room_id, room_kind, room_shard_id, capacity_profile_id, created_at)
                    VALUES (\(bind: room), 'group', 'room-a', 'standard', \(bind: now))
                    """).run()
            }
            let store = PostgresV2ContentReviewStore(database: database)
            func seed(room: UUID, sequence: Int, message: UUID = UUID()) async throws {
                try await sql.raw("""
                    INSERT INTO im_v2.messages(message_id, room_id, room_sequence, sender_user_id,
                        client_message_id, text_body, created_at, timeline_sequence)
                    VALUES (\(bind: message), \(bind: room), \(bind: sequence), \(bind: actor),
                        \(bind: UUID()), 'review', \(bind: now), \(bind: sequence))
                    """).run()
                try await sql.raw("""
                    INSERT INTO im_v2.content_review_jobs(message_id, room_id, expected_content_revision, state, created_at)
                    VALUES (\(bind: message), \(bind: room), 1, 'pending', \(bind: now))
                    """).run()
            }
            try await seed(room: frozen, sequence: 1)
            let claimed = try await store.claimPending(now: now, leaseDuration: 60, limit: 1)
            var lease = try #require(claimed.first)
            #expect(claimed.count == 1)
            let replayStore = PostgresV2DurableWorkReplayStore(database: database)
            let previousReplay = V2DurableWorkReplayCommand(operationID: UUID(),
                target: try .init(kind: .contentReview, sourceEventID: .init(lease.input.messageID.rawValue)),
                reason: .dependencyRecovered)
            try await store.scheduleRetry(lease, disposition: .pause, now: now)
            #expect(try await replayStore.replay(previousReplay, operatorPrincipal: "review-operator", now: now).outcome == .requeued)
            let reclaimed = try await store.claimPending(now: now, leaseDuration: 60, limit: 1)
            lease = try #require(reclaimed.first)
            let pausedMessage = UUID()
            try await seed(room: frozen, sequence: 3, message: pausedMessage)
            try await sql.raw("""
                UPDATE im_v2.content_review_jobs SET state = 'paused', paused_at = \(bind: now)
                WHERE message_id = \(bind: pausedMessage)
                """).run()
            try await seed(room: frozen, sequence: 2)
            try await seed(room: live, sequence: 1)
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
            func snapshot() async throws -> [String] {
                var values: [String] = []
                for table in ["content_review_jobs", "content_review_decisions", "content_review_findings", "content_review_cases", "messages", "rooms", "durable_work_replay_audit"] {
                    let rows = try await sql.raw("""
                        SELECT row_to_json(r)::text AS value FROM im_v2.\(unsafeRaw: table) AS r
                        ORDER BY row_to_json(r)::text
                        """).all(decoding: Value.self)
                    values.append(contentsOf: rows.map(\.value))
                }
                return values
            }
            let before = try await snapshot()
            let operatorCommand = V2DurableWorkReplayCommand(operationID: UUID(),
                target: try .init(kind: .contentReview, sourceEventID: .init(uuid: pausedMessage)),
                reason: .dependencyRecovered)
            await #expect(throws: V2RoomOwnerFenceError.ownerChanged) {
                _ = try await replayStore.replay(operatorCommand, operatorPrincipal: "review-operator", now: now)
            }
            let eventCommand = try V2DurableWorkEventReplayCommand(operationID: UUID(),
                kind: .contentReview, sourceEventID: .init(uuid: pausedMessage), reason: .dependencyRecovered, limit: 1)
            await #expect(throws: V2RoomOwnerFenceError.ownerChanged) {
                _ = try await replayStore.replayEvent(eventCommand, operatorPrincipal: "review-operator", now: now)
            }
            let priorReplay = try await replayStore.replay(previousReplay, operatorPrincipal: "review-operator", now: now)
            #expect(priorReplay.wasIdempotent && priorReplay.outcome == .requeued)
            #expect(try await snapshot() == before)
            try await database.transaction { holder in
                let holderSQL = try #require(holder as? any SQLDatabase)
                try await holderSQL.raw("SELECT room_id FROM im_v2.rooms WHERE room_id = \(bind: live) FOR UPDATE").run()
                try await database.transaction { contender in
                    let contenderSQL = try #require(contender as? any SQLDatabase)
                    try await contenderSQL.raw("SET LOCAL lock_timeout = '2s'").run()
                    let claimed = try await PostgresV2ContentReviewStore(database: contender)
                        .claimPending(now: now, leaseDuration: 60, limit: 10)
                    #expect(claimed.isEmpty)
                }
            }
            let finding = try V2ContentReviewFinding(category: "test", severity: 1, confidence: 0.5)
            await #expect(throws: V2RoomOwnerFenceError.ownerChanged) {
                _ = try await store.validateAndRenew(lease, now: now, leaseDuration: 60)
            }
            await #expect(throws: V2RoomOwnerFenceError.ownerChanged) {
                _ = try await store.stageViolation(lease, finding: finding)
            }
            for verdict in [V2ContentReviewVerdict.clear, .reviewRequired(finding), .violation(finding)] {
                await #expect(throws: V2RoomOwnerFenceError.ownerChanged) {
                    _ = try await store.resolve(lease, verdict: verdict, now: now)
                }
            }
            for disposition in [V2DurableRetryDisposition.retry(at: now.addingTimeInterval(1)), .pause] {
                await #expect(throws: V2RoomOwnerFenceError.ownerChanged) {
                    try await store.scheduleRetry(lease, disposition: disposition, now: now)
                }
            }
            #expect(try await snapshot() == before)
            let healthy = try await store.claimPending(now: now, leaseDuration: 60, limit: 10)
            #expect(healthy.count == 1)
            let healthyLease = try #require(healthy.first)
            #expect(healthyLease.input.roomID == .init(uuid: live))
            #expect(try await store.resolve(healthyLease, verdict: .reviewRequired(finding), now: now))
            let after = try await snapshot()
            // Neither pending work nor an expired old claim may restart on the frozen owner.
            let restarted = try await PostgresV2ContentReviewStore(database: database)
                .claimPending(now: now.addingTimeInterval(120), leaseDuration: 60, limit: 10)
            #expect(restarted.isEmpty)
            #expect(try await snapshot() == after)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
        } catch {
            if ownsSchema, let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
