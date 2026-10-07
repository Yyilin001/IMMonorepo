@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import FluentKit
import Foundation
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

@Suite("Durable direct authorization owner proof", .serialized, .timeLimit(.minutes(1)))
struct PostgresV2DirectAuthorizationReceiptTests {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    @Test func abortBarsLateAttemptAndPreservesGeneration() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let attempt = try await seed(sql: sql, schema: schema)
            let store = PostgresV2DirectAuthorizationReceiptStore(schema: schema)
            let aborted = try await store.abort(attempt, now: now, database: database)
            #expect(aborted == .init(disposition: .aborted, eventID: nil))
            let late = try await database.transaction { transaction in
                try await store.prepare(attempt, transaction: transaction)
            }
            #expect(late == aborted)
            await #expect(throws: V2DirectAuthorizationReceiptError.attemptAborted) {
                try await database.transaction { try await store.finish(attempt, now: now, transaction: $0) }
            }
            #expect(try await store.abort(attempt, now: now.addingTimeInterval(100), database: database) == aborted)
            let next = copy(attempt, generation: 2)
            try await database.transaction { transaction async throws -> Void in
                #expect(try await store.prepare(next, transaction: transaction) == nil)
            }
            #expect(try await store.abort(next, now: now, database: database) == aborted)
            // The old generation remains barred even after a newer one exists.
            #expect(try await store.abort(attempt, now: now, database: database) == aborted)
            for changed in [copy(attempt, generation: 1, fingerprint: Data(repeating: 9, count: 32)),
                            copy(attempt, generation: 3, fingerprint: Data(repeating: 9, count: 32))] {
                await #expect(throws: V2DirectAuthorizationReceiptError.identityConflict) {
                    try await store.abort(changed, now: now, database: database)
                }
            }
            // Leave a gap: a missing exact generation must reject a future
            // terminal attempt, while old exact proofs still take priority.
            #expect(try await store.abort(copy(attempt, generation: 4), now: now, database: database) == aborted)
            #expect(try await store.abort(attempt, now: now, database: database) == aborted)
            for changed in [copy(attempt, generation: 3),
                            copy(attempt, generation: 1, recipientID: UUID()),
                            copy(attempt, generation: 1, ownerShardID: "other-owner"),
                            copy(attempt, generation: 1, ownerEpoch: 1),
                            copy(attempt, generation: 5, recipientID: UUID())] {
                await #expect(throws: V2DirectAuthorizationReceiptError.identityConflict) {
                    try await database.transaction { try await store.checkAttempt(changed, transaction: $0) }
                }
            }
            // Prior proofs bind recipient/fingerprint, not the new route.
            // The caller still performs the independent owner fence afterward.
            try await database.transaction { transaction async throws -> Void in
                let rerouted = copy(attempt, generation: 5, ownerShardID: "other-owner", ownerEpoch: 1)
                #expect(try await store.checkAttempt(rerouted, transaction: transaction) == nil)
            }
            for mutation in ["UPDATE \(schema).direct_authorization_receipts SET generation = 99",
                             "DELETE FROM \(schema).direct_authorization_receipts"] {
                await #expect(throws: (any Error).self) { try await sql.raw("\(unsafeRaw: mutation)").run() }
            }
            let count = try #require(try await sql.raw("SELECT count(*) AS value FROM \(unsafeRaw: schema).direct_authorization_receipts").first(decoding: Count.self))
            #expect(count.value == 3)
        }
    }

    @Test(arguments: [false, true])
    func revokeWaitsForOwnerCommitOrRollback(rollback: Bool) async throws {
        try await withUserEventDatabase { database, sql, schema in
            let attempt = try await seed(sql: sql, schema: schema)
            let store = PostgresV2DirectAuthorizationReceiptStore(schema: schema)
            let gate = ReceiptTransactionGate()
            let eventID = UUID()
            let owner = Task {
                try await database.transaction { transaction in
                    #expect(try await store.prepare(attempt, transaction: transaction) == nil)
                    let ownerSQL = try #require(transaction as? any SQLDatabase)
                    try await insertCompletion(attempt, eventID: eventID, sql: ownerSQL, schema: schema)
                    #expect(try await store.finish(attempt, now: now, transaction: transaction) == .init(disposition: .accepted, eventID: eventID))
                    await gate.hold()
                    if rollback { throw ProbeError.rollback }
                }
            }
            await gate.waitUntilHeld()
            let revoker = Task { try await store.abort(attempt, now: now, database: database) }
            do {
                var waiting = false
                for _ in 0..<200 {
                    let key = "v2-message-operation:" + attempt.roomID.uuidString.lowercased() + ":" + attempt.senderID.uuidString.lowercased() + ":" + attempt.clientMessageID.uuidString.lowercased()
                    let locks = try #require(try await sql.raw("""
                        SELECT count(*) AS value FROM pg_locks
                        WHERE locktype = 'advisory' AND NOT granted
                          AND classid::bigint = ((hashtextextended(\(bind: key), 0) >> 32) & 4294967295)
                          AND objid::bigint = (hashtextextended(\(bind: key), 0) & 4294967295)
                        """).first(decoding: Count.self))
                    if locks.value > 0 { waiting = true; break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(waiting, "revocation must wait for the exact in-flight message operation")
                await gate.release()
                if rollback {
                    await #expect(throws: ProbeError.rollback) { try await owner.value }
                } else { try await owner.value }
                let result = try await revoker.value
                #expect(result == .init(disposition: rollback ? .aborted : .accepted, eventID: rollback ? nil : eventID))
                let late = try await database.transaction { try await store.prepare(attempt, transaction: $0) }
                #expect(late == result)
                let count = try #require(try await sql.raw("SELECT count(*) AS value FROM \(unsafeRaw: schema).message_send_completions").first(decoding: Count.self))
                #expect(count.value == (rollback ? 0 : 1))
            } catch {
                await gate.release()
                _ = await owner.result
                _ = await revoker.result
                throw error
            }
        }
    }

    @Test func rejectsUnprovenCompletionAndStaleOwner() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let attempt = try await seed(sql: sql, schema: schema)
            let store = PostgresV2DirectAuthorizationReceiptStore(schema: schema)
            await #expect(throws: V2DirectAuthorizationReceiptError.transactionRequired) {
                try await store.prepare(attempt, transaction: database)
            }
            await #expect(throws: V2DirectAuthorizationReceiptError.missingCompletion) {
                try await database.transaction { try await store.finish(attempt, now: now, transaction: $0) }
            }
            try await sql.raw("UPDATE \(unsafeRaw: schema).rooms SET owner_epoch = 1 WHERE room_id = \(bind: attempt.roomID)").run()
            await #expect(throws: V2DirectAuthorizationReceiptError.ownerChanged) {
                try await store.abort(attempt, now: now, database: database)
            }
            let count = try #require(try await sql.raw("SELECT count(*) AS value FROM \(unsafeRaw: schema).direct_authorization_receipts").first(decoding: Count.self))
            #expect(count.value == 0)
        }
    }

    @Test(arguments: ["trigger", "constraint", "function"])
    func readinessRejectsMissingProofGuards(drift: String) async throws {
        try await withUserEventDatabase { database, sql, schema in
            try await V2SchemaReadiness.verify(database: database, schema: schema)
            switch drift {
            case "trigger":
                try await sql.raw("ALTER TABLE \(unsafeRaw: schema).direct_authorization_receipts DISABLE TRIGGER direct_authorization_receipts_immutable").run()
            case "constraint":
                try await sql.raw("ALTER TABLE \(unsafeRaw: schema).direct_authorization_receipts DROP CONSTRAINT direct_authorization_receipt_result_check").run()
            default:
                try await sql.raw("""
                    CREATE OR REPLACE FUNCTION \(unsafeRaw: schema).reject_direct_authorization_receipt_mutation()
                    RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END; $$
                    """).run()
            }
            await #expect(throws: V2SchemaReadinessError.unavailableTable(schema + ".direct_authorization_receipts[terminal-proof]")) {
                try await V2SchemaReadiness.verify(database: database, schema: schema)
            }
        }
    }

    private func seed(sql: any SQLDatabase, schema: String) async throws -> V2DirectAuthorizationAttempt {
        let users = [UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
        let attempt = V2DirectAuthorizationAttempt(roomID: UUID(), senderID: users[0], clientMessageID: UUID(),
            generation: 1, recipientID: users[1], ownerShardID: "receipt-owner", ownerEpoch: 0,
            fingerprint: Data(repeating: 7, count: 32))
        try await sql.raw("""
            INSERT INTO \(unsafeRaw: schema).rooms (room_id, room_kind, room_shard_id, capacity_profile_id)
            VALUES (\(bind: attempt.roomID), 'direct', 'receipt-owner', 'standard')
            """).run()
        try await sql.raw("""
            INSERT INTO \(unsafeRaw: schema).direct_room_pairs (lower_user_id, higher_user_id, room_id, created_at)
            VALUES (\(bind: users[0]), \(bind: users[1]), \(bind: attempt.roomID), \(bind: now))
            """).run()
        return attempt
    }

    private func copy(_ attempt: V2DirectAuthorizationAttempt, generation: Int64, fingerprint: Data? = nil,
                      recipientID: UUID? = nil, ownerShardID: String? = nil, ownerEpoch: Int64? = nil) -> V2DirectAuthorizationAttempt {
        .init(roomID: attempt.roomID, senderID: attempt.senderID, clientMessageID: attempt.clientMessageID,
            generation: generation, recipientID: recipientID ?? attempt.recipientID,
            ownerShardID: ownerShardID ?? attempt.ownerShardID,
            ownerEpoch: ownerEpoch ?? attempt.ownerEpoch, fingerprint: fingerprint ?? attempt.fingerprint)
    }

    private func insertCompletion(_ attempt: V2DirectAuthorizationAttempt, eventID: UUID, sql: any SQLDatabase, schema: String) async throws {
        try await sql.raw("""
            INSERT INTO \(unsafeRaw: schema).message_send_completions
                (room_id, sender_user_id, client_message_id, fingerprint_version, request_fingerprint,
                 message_id, event_id, room_sequence, timeline_sequence, accepted_membership_revision,
                 direct_recipient_user_id, created_at)
            VALUES (\(bind: attempt.roomID), \(bind: attempt.senderID), \(bind: attempt.clientMessageID), 3,
                \(bind: attempt.fingerprint), \(bind: UUID()), \(bind: eventID), 1, 1, 0,
                \(bind: attempt.recipientID), \(bind: now))
            """).run()
    }
    private struct Count: Decodable { let value: Int64 }
    private enum ProbeError: Error { case rollback }
}

private actor ReceiptTransactionGate {
    private var held = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func hold() async {
        held = true
        waiter?.resume(); waiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitUntilHeld() async {
        if !held { await withCheckedContinuation { waiter = $0 } }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}
