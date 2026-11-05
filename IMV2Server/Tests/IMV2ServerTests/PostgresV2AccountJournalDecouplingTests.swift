@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
@testable import IMV2ServerInfrastructure
import FluentKit
import Foundation
import IMV2Core
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("journal appends while snapshot is paused and concurrent wake cannot disappear")
    func accountJournalIndependentSnapshotAndWake() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, room in
            let user = UserID(uuid: memberTwoUUID)
            let projector = try PostgresV2UserStateEventProjector(database: database)
            let first = try journalTestLease(sequence: 1, room: room)
            try await projector.appendRoomChanges([.init(userID: user, leases: [first])])
            // Pause actual snapshot work after its first version is inserted,
            // while its transaction owns the consumer checkpoint.
            try await sql.raw("""
                CREATE FUNCTION im_v2.pause_snapshot_test() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN PERFORM pg_advisory_xact_lock(728194); RETURN NEW; END $$;
                """).run()
            try await sql.raw("CREATE TRIGGER pause_snapshot_test AFTER INSERT ON im_v2.user_projection_versions FOR EACH ROW EXECUTE FUNCTION im_v2.pause_snapshot_test()").run()
            let entered = AsyncStream<Void>.makeStream(), release = AsyncStream<Void>.makeStream()
            defer { release.continuation.finish(); entered.continuation.finish() }
            async let blocker: Void = database.transaction { db in
                let tx = try #require(db as? any SQLDatabase)
                try await tx.raw("SELECT pg_advisory_xact_lock(728194)").run()
                entered.continuation.yield(())
                for await _ in release.stream { break }
            }
            for await _ in entered.stream { break }
            let worker = PostgresV2UserProjectionWorker(database: database)
            async let projection = worker.runOnce()
            let deadline = ContinuousClock.now + .seconds(10)
            while true {
                let waiting = try await sql.raw("SELECT count(*)::bigint AS value FROM pg_locks WHERE locktype='advisory' AND objid=728194 AND NOT granted")
                    .first(decoding: JournalCount.self)?.value ?? 0
                if waiting > 0 { break }
                try #require(ContinuousClock.now < deadline, "snapshot did not reach the hold point")
                try await Task.sleep(for: .milliseconds(10))
            }
            do {
                // A shared checkpoint lock would fail deterministically here.
                try await database.transaction { db in
                    let tx = try #require(db as? any SQLDatabase)
                    try await tx.raw("SET LOCAL lock_timeout='500ms'").run()
                    try await PostgresV2UserStateEventProjector(database: db).appendRoomChanges([
                        .init(userID: user, leases: [try journalTestLease(sequence: 2, room: room)])])
                }
            } catch { release.continuation.finish(); throw error }
            #expect(try await count("im_v2.user_sync_log", on: sql) == 2)
            release.continuation.yield(())
            try await blocker
            #expect(try await projection.appliedRecordCount == 1)
            #expect(try await count("im_v2.user_projection_ready", on: sql) == 1)
            #expect(try await worker.runOnce().appliedRecordCount == 1)
            #expect(try await count("im_v2.user_projection_ready", on: sql) == 0)
            let heads = try await sql.raw("SELECT (payload->>'room_sequence')::bigint AS value FROM im_v2.user_projection_versions WHERE projection_kind='room_head' AND valid_to_sequence IS NULL").all(decoding: JournalCount.self)
            #expect(heads.map(\.value) == [2])
        }
    }

    @Test("storage shard batch preserves per-user order, rollback, deduplication and snapshot cuts")
    func accountJournalBatchAtomicityAndReplay() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, room in
            let user = UserID(uuid: memberTwoUUID), other = UserID(uuid: memberThreeUUID)
            let leases = try (1...12).map { try journalTestLease(sequence: UInt64($0), room: room) }
            let targets = [V2RoomDispatchTarget(userID: user, leases: leases), .init(userID: other, leases: leases)]
            let projector = try PostgresV2UserStateEventProjector(database: database)
            try await sql.raw("ALTER TABLE im_v2.account_notification_outbox ADD CONSTRAINT injected_journal_failure CHECK(room_sequence<>7) NOT VALID").run()
            await #expect(throws: (any Error).self) { try await projector.appendRoomChanges(targets) }
            for table in ["user_sync_sequences","user_sync_log","user_state_event_receipts","account_notification_outbox"] {
                #expect(try await count("im_v2.\(table)", on: sql) == 0)
            }
            try await sql.raw("ALTER TABLE im_v2.account_notification_outbox DROP CONSTRAINT injected_journal_failure").run()
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<6 { group.addTask { try await projector.appendRoomChanges(index.isMultiple(of: 2) ? targets : targets.reversed()) } }
                try await group.waitForAll()
            }
            #expect(try await count("im_v2.user_sync_log", on: sql) == 24)
            #expect(try await count("im_v2.account_notification_outbox", on: sql) == 24)
            let wrong = try journalTestLease(sequence: 99, room: room, event: leases[0].eventID)
            await #expect(throws: V2UserStateEventError.self) { try await projector.appendRoomChanges([.init(userID: user, leases: [wrong])]) }
            let worker = PostgresV2UserProjectionWorker(database: database)
            #expect(try await worker.runOnce().appliedRecordCount == 12)
            #expect(try await worker.runOnce().appliedRecordCount == 12)
            let versions = try await sql.raw("""
                SELECT count(*)::bigint AS value FROM im_v2.user_projection_versions
                WHERE projection_kind='room_head'
                  AND valid_from_sequence=(payload->>'room_sequence')::bigint
                  AND (valid_to_sequence=valid_from_sequence+1 OR (valid_from_sequence=12 AND valid_to_sequence IS NULL))
                """).first(decoding: JournalCount.self)
            #expect(versions?.value == 24)
        }
    }
}
private struct JournalCount: Decodable { let value: Int64 }
private func journalTestLease(sequence: UInt64, room: RoomID, event: UUID = UUID()) throws -> V2RoomDispatchLease {
    .init(eventID: event, messageID: UUID(), roomID: room, roomSequence: sequence, membershipRevision: 0,
          senderID: .init(uuid: UUID()), mentionedUserIDs: [], mentionsEveryone: false,
          createdAtTimestamp: try .init(date: Date()), recipientCursor: nil, token: UUID(), attempt: 1,
          expiresAt: Date().addingTimeInterval(30))
}
