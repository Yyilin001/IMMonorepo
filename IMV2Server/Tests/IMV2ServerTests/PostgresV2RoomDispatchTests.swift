@testable import IMV2ServerInfrastructure
import FluentKit
import Foundation
import IMV2Core
import IMV2ServerContracts
import IMV2ServerApplication
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("message dispatch rolls back with source work and pages the historical audience under fenced leases")
    func messageDispatchAtomicityAndAudience() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { _, owner, _, sql, room in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let event = UUID(), message = UUID()
            @Sendable func enqueue(_ transaction: any SQLDatabase) async throws {
                try await v2EnqueueMessageDispatch(eventID: event, messageID: message,
                    roomID: room.uuidValue!, roomSequence: 1, membershipRevision: 3,
                    senderID: senderUUID, mentionedUserIDs: [memberThreeUUID], mentionsEveryone: false,
                    createdAt: now, sql: transaction)
            }
            await #expect(throws: DispatchRollback.self) {
                try await owner.transaction { db in
                    try await enqueue(try #require(db as? any SQLDatabase))
                    throw DispatchRollback.expected
                }
            }
            #expect(try await count("im_v2.room_dispatch_outbox", on: sql) == 0)
            try await enqueue(sql)
            // A departed member who rejoins later must not receive gap events.
            try await sql.raw("""
                UPDATE im_v2.room_memberships SET left_revision = 2
                WHERE room_id = \(bind: room.uuidValue!) AND user_id = \(bind: memberTwoUUID);
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_memberships(room_id,user_id,joined_revision)
                VALUES (\(bind: room.uuidValue!),\(bind: memberTwoUUID),5)
                """).run()
            let store = PostgresV2RoomDispatchStore(database: owner)
            let old = try #require(try await store.claim(now: now, limit: 1, leaseDuration: 1).first)
            #expect(try await store.claim(now: now, limit: 1).isEmpty)
            let later = now.addingTimeInterval(2)
            let current = try #require(try await store.claim(now: later, limit: 1).first)
            #expect(current.token != old.token)
            await #expect(throws: V2RoomDispatchError.self) {
                _ = try await store.recipients(old, limit: 10, now: later)
            }
            #expect(try await !store.acknowledgePage(old, through: senderUUID, now: later))
            #expect(try await !store.acknowledgePage(current, through: nil, now: later))
            #expect(try await store.acknowledgePages([.init(lease: old, through: senderUUID)], now: later).isEmpty)
            #expect(try await store.acknowledgePages([.init(lease: current, through: nil)], now: later).isEmpty)
            #expect(current.mentionedUserIDs == [UserID(uuid: memberThreeUUID)])
            let first = try await store.recipients(current, limit: 1, now: later)
            #expect(first.count == 1)
            #expect(try await store.acknowledgePage(current, through: first[0].uuidValue!, now: later))
            let secondLease = try #require(try await store.claim(now: later, limit: 1).first)
            let second = try await store.recipients(secondLease, limit: 10, now: later)
            #expect(Set(first + second) == [UserID(uuid: senderUUID), UserID(uuid: memberThreeUUID)])
            #expect(try await store.acknowledgePages([.init(lease: secondLease, through: try #require(second.last?.uuidValue))], now: later) == [secondLease.eventID])
            #expect(try await store.claim(now: later, limit: 1).isEmpty)
            #expect(try await !store.acknowledgePage(secondLease, through: second.last?.uuidValue, now: later))
            #expect(try await count("im_v2.room_dispatch_outbox", on: sql) == 0)
        }
    }
}
private enum DispatchRollback: Error { case expected }

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("offline account hint and notification intent commit atomically and survive lost source acknowledgement")
    func messageDispatchDurableTargetAndRetry() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { target, owner, targetSQL, ownerSQL, room in
            let now = Date(), event = UUID()
            try await v2EnqueueMessageDispatch(eventID: event, messageID: UUID(), roomID: room.uuidValue!,
                roomSequence: 1, membershipRevision: 0, senderID: senderUUID,
                mentionedUserIDs: [memberThreeUUID], mentionsEveryone: false, createdAt: now, sql: ownerSQL)
            let source = PostgresV2RoomDispatchStore(database: owner)
            let lease = try #require(try await source.claim(now: now, limit: 1).first)
            let projector = try PostgresV2UserStateEventProjector(database: target)
            let recipient = UserID(uuid: memberTwoUUID)
            // Fail the last target write: receipt, sequence, log and wake must all roll back.
            try await targetSQL.raw("ALTER TABLE im_v2.account_notification_outbox ADD CONSTRAINT injected_failure CHECK (false) NOT VALID").run()
            await #expect(throws: (any Error).self) { _ = try await projector.projectRoomChange(lease, to: recipient) }
            for table in ["user_state_event_receipts", "user_sync_sequences", "user_sync_log", "user_sync_wake_outbox", "account_notification_outbox"] {
                #expect(try await count("im_v2.\(table)", on: targetSQL) == 0)
            }
            try await targetSQL.raw("ALTER TABLE im_v2.account_notification_outbox DROP CONSTRAINT injected_failure").run()
            let first = try await projector.projectRoomChange(lease, to: recipient)
            #expect(first == 1)
            #expect(try await count("im_v2.account_notification_outbox", on: targetSQL) == 1)
            // Model successful notification consumption before source ACK is retried.
            try await targetSQL.raw("DELETE FROM im_v2.account_notification_outbox").run()
            #expect(try await projector.projectRoomChange(lease, to: recipient) == first)
            #expect(try await count("im_v2.account_notification_outbox", on: targetSQL) == 0)
            try await source.retry(lease, now: now, after: 0)
            let delivery = DispatchFaultProjector(projector: projector)
            let firstWorker = V2RoomDispatchWorker(outbox: source, projector: delivery, concurrency: 1, now: { now })
            let failed = try await firstWorker.runOnce(limit: 8)
            #expect(failed.failedPages == 1)
            #expect(try await count("im_v2.room_dispatch_outbox", on: ownerSQL) == 1)
            let retryTime = now.addingTimeInterval(10)
            let retryWorker = V2RoomDispatchWorker(outbox: source, projector: delivery, concurrency: 1, pageSize: 1, now: { retryTime })
            let retried = try await retryWorker.runOnce(limit: 8)
            #expect(retried.failedPages == 0)
            #expect(try await count("im_v2.room_dispatch_outbox", on: ownerSQL) == 0)
            #expect(try await count("im_v2.user_sync_log", on: targetSQL) == 3)
            #expect(try await count("im_v2.user_state_event_receipts", on: targetSQL) == 3)
            // All three accounts sync, but only the other still-pending recipient gets a notification.
            #expect(try await count("im_v2.account_notification_outbox", on: targetSQL) == 1)
            let alert = try #require(try await targetSQL.raw("SELECT user_id, is_mention FROM im_v2.account_notification_outbox")
                .first(decoding: DispatchAlertRow.self))
            #expect(alert.user_id == memberThreeUUID && alert.is_mention)
        }
    }

    @Test("account room head snapshots are monotonic and cannot revive revoked membership")
    func messageDispatchSnapshotOrderingAndRevocation() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { target, owner, sql, ownerSQL, room in
            let now = Date(), user = UserID(uuid: memberTwoUUID)
            let projector = try PostgresV2UserStateEventProjector(database: target)
            let outbox = PostgresV2RoomDispatchStore(database: owner)
            func dispatch(_ sequence: Int64, _ revision: Int64) async throws {
                try await v2EnqueueMessageDispatch(eventID: UUID(), messageID: UUID(), roomID: room.uuidValue!,
                    roomSequence: sequence, membershipRevision: revision, senderID: senderUUID,
                    mentionedUserIDs: [], mentionsEveryone: false, createdAt: now, sql: ownerSQL)
                let lease = try #require(try await outbox.claim(now: now, limit: 1).first)
                _ = try await projector.projectRoomChange(lease, to: user)
            }
            try await dispatch(9, 2)
            try await dispatch(5, 1)
            let worker = PostgresV2UserProjectionWorker(database: target)
            let applied = try await worker.runOnce(now: now.addingTimeInterval(5))
            #expect(applied.appliedRecordCount == 2 && applied.failedRecordCount == 0)
            let head = try #require(try await sql.raw("""
                SELECT payload->>'room_sequence' AS head FROM im_v2.user_projection_versions
                WHERE projection_kind = 'room_head' AND valid_to_sequence IS NULL
                """).first(decoding: DispatchHeadRow.self))
            #expect(head.head == "9")
            let revoke = try V2UserStateEvent(sourceEventID: .init(uuid: UUID()), userID: user, kind: .membership,
                payload: JSONSerialization.data(withJSONObject: ["event_type": "membership_changed", "room_id": room.rawValue,
                    "membership_revision": 3, "action": "remove", "target_user_id": user.rawValue]), createdAt: now)
            _ = try await projector.project(revoke)
            try await dispatch(7, 2)
            let revoked = try await worker.runOnce(now: now.addingTimeInterval(5))
            #expect(revoked.appliedRecordCount == 2 && revoked.failedRecordCount == 0)
            #expect(try await sql.raw("""
                SELECT count(*)::bigint AS count FROM im_v2.user_projection_versions
                WHERE projection_kind = 'room_head' AND valid_to_sequence IS NULL
                """).first(decoding: DispatchCountRow.self)?.count == 0)
        }
    }
}

private actor DispatchFaultProjector: V2RoomDispatchProjecting {
    let projector: PostgresV2UserStateEventProjector
    var failOnce = true
    init(projector: PostgresV2UserStateEventProjector) { self.projector = projector }
    func project(_ lease: V2RoomDispatchLease, to userID: UserID) async throws {
        _ = try await projector.projectRoomChange(lease, to: userID)
        if failOnce { failOnce = false; throw DispatchRollback.expected }
    }
}
private struct DispatchAlertRow: Decodable { let user_id: UUID; let is_mention: Bool }
private struct DispatchHeadRow: Decodable { let head: String }
private struct DispatchCountRow: Decodable { let count: Int64 }

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("room edits and controls retain durable recovery after source-log pruning without creating alerts")
    func roomChangeDispatchWithoutMessage() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { target, owner, sql, ownerSQL, room in
            let now = Date(), event = UUID()
            @Sendable func insert(_ sql: any SQLDatabase) async throws {
                try await sql.raw("""
                    INSERT INTO im_v2.room_events(event_id, room_id, room_sequence, event_type,
                        actor_user_id, payload, committed_membership_revision, created_at)
                    VALUES (\(bind: event), \(bind: room.uuidValue!), 1, 'message.withdrawn',
                        NULL, '{}'::jsonb, 0, \(bind: now))
                    """).run()
            }
            await #expect(throws: DispatchRollback.self) {
                try await owner.transaction { db in
                    try await insert(try #require(db as? any SQLDatabase))
                    throw DispatchRollback.expected
                }
            }
            #expect(try await count("im_v2.room_dispatch_outbox", on: ownerSQL) == 0)
            try await insert(ownerSQL)
            try await owner.transaction { db in
                let trim = try #require(db as? any SQLDatabase)
                try await trim.raw("SET LOCAL im_v2.retention_trim = 'on'").run()
                try await trim.raw("UPDATE im_v2.rooms SET room_sequence = 2, log_trimmed_through_room_sequence = 2 WHERE room_id = \(bind: room.uuidValue!)").run()
                try await trim.raw("DELETE FROM im_v2.room_events WHERE event_id = \(bind: event)").run()
            }
            #expect(try await count("im_v2.room_dispatch_outbox", on: ownerSQL) == 1)
            let projector = DispatchDirectProjector(projector: try .init(database: target))
            let worker = V2RoomDispatchWorker(outbox: PostgresV2RoomDispatchStore(database: owner), projector: projector)
            let report = try await worker.runOnce(limit: 10)
            #expect(report.failedPages == 0)
            #expect(try await count("im_v2.room_dispatch_outbox", on: ownerSQL) == 0)
            #expect(try await count("im_v2.user_sync_log", on: sql) == 3)
            #expect(try await count("im_v2.account_notification_outbox", on: sql) == 0)
        }
    }
}
private struct DispatchDirectProjector: V2RoomDispatchProjecting {
    let projector: PostgresV2UserStateEventProjector
    func project(_ lease: V2RoomDispatchLease, to userID: UserID) async throws {
        _ = try await projector.projectRoomChange(lease, to: userID)
    }
}

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("readiness rejects missing dispatch trigger and broken notification lease shape")
    func roomDispatchSchemaContract() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            try await V2SchemaReadiness.verify(database: database)
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let contract = try String(contentsOf: root.appending(path: "IMV2/scripts/current_v2_schema_contract.sql"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ";"))
            #expect(try await sql.raw("SELECT * FROM (\(unsafeRaw: contract)) contract(ready)")
                .first(decoding: DispatchReadyRow.self)?.ready == true)
            try await sql.raw("ALTER TABLE im_v2.room_events DISABLE TRIGGER room_events_account_dispatch").run()
            await #expect(throws: V2SchemaReadinessError.unavailableTable("im_v2.room_dispatch[contract]")) {
                try await V2SchemaReadiness.verify(database: database)
            }
            try await sql.raw("ALTER TABLE im_v2.room_events ENABLE TRIGGER room_events_account_dispatch").run()
            try await V2SchemaReadiness.verify(database: database)
            try await sql.raw("ALTER TABLE im_v2.account_notification_outbox DROP COLUMN claim_token CASCADE").run()
            await #expect(throws: V2SchemaReadinessError.unavailableTable("im_v2.room_dispatch[contract]")) {
                try await V2SchemaReadiness.verify(database: database)
            }
        }
    }
}

private struct DispatchReadyRow: Decodable { let ready: Bool }

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("concurrent account deliveries keep one receipt and contiguous durable sequences")
    func messageDispatchConcurrentAccountCommit() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { target, owner, sql, ownerSQL, room in
            let now = Date(), recipient = UserID(uuid: memberTwoUUID)
            for sequence in 1...12 {
                try await v2EnqueueMessageDispatch(eventID: UUID(), messageID: UUID(), roomID: room.uuidValue!,
                    roomSequence: Int64(sequence), membershipRevision: 0, senderID: senderUUID,
                    mentionedUserIDs: [], mentionsEveryone: false, createdAt: now, sql: ownerSQL)
            }
            let leases = try await PostgresV2RoomDispatchStore(database: owner).claim(now: now, limit: 12)
            #expect(leases.count == 12)
            let projector = try PostgresV2UserStateEventProjector(database: target)
            let sequences = try await withThrowingTaskGroup(of: UInt64.self, returning: [UInt64].self) { tasks in
                for lease in leases {
                    for _ in 0..<3 { tasks.addTask { try await projector.projectRoomChange(lease, to: recipient) } }
                }
                var values: [UInt64] = []
                for try await value in tasks { values.append(value) }
                return values
            }
            #expect(Set(sequences) == Set(UInt64(1)...UInt64(12)))
            for sequence in 1...12 { #expect(sequences.filter { $0 == UInt64(sequence) }.count == 3) }
            for table in ["user_state_event_receipts", "user_sync_log", "account_notification_outbox"] {
                #expect(try await count("im_v2.\(table)", on: sql) == 12)
            }
        }
    }
}

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("account projection batches roll back together and retain every source after a lost target response")
    func messageDispatchAccountBatchAtomicity() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { target, owner, sql, ownerSQL, room in
            let now = Date(), recipient = UserID(uuid: memberTwoUUID)
            for sequence in 1...4 {
                try await v2EnqueueMessageDispatch(eventID: UUID(), messageID: UUID(), roomID: room.uuidValue!,
                    roomSequence: Int64(sequence), membershipRevision: 0, senderID: senderUUID,
                    mentionedUserIDs: [], mentionsEveryone: false, createdAt: now, sql: ownerSQL)
            }
            let source = PostgresV2RoomDispatchStore(database: owner)
            let leases = try await source.claim(now: now, limit: 4)
            let projector = try PostgresV2UserStateEventProjector(database: target)
            try await sql.raw("ALTER TABLE im_v2.account_notification_outbox ADD CONSTRAINT injected_batch_failure CHECK (room_sequence <> 3) NOT VALID").run()
            await #expect(throws: (any Error).self) {
                try await projector.projectRoomChanges(leases.sorted { $0.roomSequence < $1.roomSequence }, to: recipient)
            }
            for table in ["user_state_event_receipts", "user_sync_sequences", "user_sync_log", "user_sync_wake_outbox", "account_notification_outbox"] {
                #expect(try await count("im_v2.\(table)", on: sql) == 0)
            }
            try await sql.raw("ALTER TABLE im_v2.account_notification_outbox DROP CONSTRAINT injected_batch_failure").run()
            for lease in leases { try await source.retry(lease, now: now, after: 0) }
            let sink = DispatchBatchLostResponse(projector: projector, failUser: recipient)
            let initial = try await V2RoomDispatchWorker(outbox: source, projector: sink, now: { now }).runOnce(limit: 4)
            #expect(initial.failedPages == 4 && initial.acknowledgedPages == 0)
            #expect(await sink.largestBatch == 4)
            #expect(try await count("im_v2.room_dispatch_outbox", on: ownerSQL) == 4)
            let later = now.addingTimeInterval(10)
            let retry = try await V2RoomDispatchWorker(outbox: source, projector: sink, now: { later }).runOnce(limit: 4)
            #expect(retry.failedPages == 0 && retry.acknowledgedPages == 4)
            #expect(try await count("im_v2.room_dispatch_outbox", on: ownerSQL) == 0)
            #expect(try await count("im_v2.user_sync_log", on: sql) == 12)
            #expect(try await count("im_v2.user_state_event_receipts", on: sql) == 12)
            #expect(try await count("im_v2.account_notification_outbox", on: sql) == 8)
        }
    }
}

private actor DispatchBatchLostResponse: V2RoomDispatchProjecting {
    let projector: PostgresV2UserStateEventProjector
    let failUser: UserID
    var failed = false
    private(set) var largestBatch = 0
    init(projector: PostgresV2UserStateEventProjector, failUser: UserID) {
        self.projector = projector; self.failUser = failUser
    }
    func project(_ lease: V2RoomDispatchLease, to userID: UserID) async throws {
        try await project([lease], to: userID)
    }
    func project(_ leases: [V2RoomDispatchLease], to userID: UserID) async throws {
        largestBatch = max(largestBatch, leases.count)
        try await projector.projectRoomChanges(leases, to: userID)
        if userID == failUser && !failed { failed = true; throw DispatchRollback.expected }
    }
}
