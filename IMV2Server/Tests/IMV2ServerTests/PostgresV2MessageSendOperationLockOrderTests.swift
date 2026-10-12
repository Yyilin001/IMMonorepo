@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core
import FluentKit
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("current policy preparation preserves handle identity and deadlines without durable reservations")
    func currentPolicyPreparationPreservesIdentityAndDeadlines() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let direct = try await V2DirectRoomOperationTestFixture(database: database,
                capacityProfile: profile, roomShardID: "room-a", roomID: .init(uuid: UUID()), now: { now })
                .openedIdentity(actorUserID: senderID, operationID: .init(uuid: UUID()),
                    targetUserID: .init(uuid: memberTwoUUID), firstSubmissionDeadlineMilliseconds: 1_750_000_600_000)
            let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000041")!
            let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
            let deadline = UInt64(now.timeIntervalSince1970 * 1000) + 60_000
            @Sendable func command(_ id: UUID, _ text: String) throws -> V2MessageSendOperationCommand {
                try .init(command: .init(roomID: direct.roomID, senderUserID: senderID,
                    clientMessageID: .init(uuid: id), text: text, limits: .init(maxUTF8Bytes: 64)),
                    firstSubmissionDeadlineMilliseconds: deadline)
            }
            let first = try command(firstID, "first authorization")
            let second = try command(secondID, "second authorization")
            let policies = v2FixtureRoomPolicyAuthorizations(database: database)
            let store = PostgresV2MessageSendOperationStore(database: database,
                writes: PostgresV2RoomWriteStore(database: database,
                    strangerMessagePolicy: try .init(maximumMessagesPerWindow: 100, window: 86_400),
                    contentReviewMode: .disabled).usingControlDatabase(database).usingPolicyAuthorizations(policies), clock: { now })
            let results = try await withRoomActivation(database: database, roomID: direct.roomID) { token in
                let originalDeadline = ContinuousClock.now + .seconds(30)
                let prepared = try await policies.fixtureSendPreparation(store: store, now: { now })(
                    [first, second], token, originalDeadline)
                #expect(prepared.deadline <= originalDeadline)
                #expect(try await count("im_v2.messages", on: sql) == 0)
                #expect(try await count("im_v2.message_send_completions", on: sql) == 0)
                let differentStore = PostgresV2MessageSendOperationStore(database: database,
                    writes: PostgresV2RoomWriteStore(database: database).usingControlDatabase(database), clock: { now })
                await #expect(throws: V2RoomCallFailure.notAccepted(.invalidRequest)) {
                    _ = try await differentStore.executePreparedSendBatch(prepared, capacityProfile: profile,
                        identifiers: .init(), now: { now })
                }
                // Moving the handle to another task cannot enlarge that
                // caller's earlier SQL deadline or start the owner transaction.
                await #expect(throws: V2RoomPolicyExecutionFailure.expired) {
                    try await V2RoomSQLDeadline.withDeadline(ContinuousClock.now - .seconds(1)) {
                        _ = try await store.executePreparedSendBatch(prepared, capacityProfile: profile,
                            identifiers: .init(), now: { now })
                    }
                }
                #expect(try await count("im_v2.messages", on: sql) == 0)
                // A value copy still represents this same owner store.
                let sameStore = store
                return try await sameStore.executePreparedSendBatch(prepared, capacityProfile: profile,
                    identifiers: .init(), now: { now })
            }
            #expect(results.count == 2)
            for result in results {
                guard case .sendOperation(.receipt(let receipt)) = result,
                      case .accepted = receipt.outcome else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
            }
            try await assertRetiredDirectAuthorizationSchemaAbsent(on: sql)
            // Recovery queries use only the original durable success identity,
            // even after the current direct-room policy route disappears.
            try await sql.raw("DELETE FROM im_v2.direct_room_pairs WHERE room_id = \(bind: direct.roomID.uuidValue!)").run()
            let replayStore = PostgresV2MessageSendOperationStore(database: database,
                writes: PostgresV2RoomWriteStore(database: database, contentReviewMode: .disabled),
                clock: { now })
            try await withRoomActivation(database: database, roomID: direct.roomID) { token in
                let request = try V2MessageSendOperationRecoveryRequest(identity: first.identity,
                    fingerprint: first.fingerprint, domainFingerprint: first.command.fingerprint)
                #expect(try await replayStore.recover(request, token: token) == {
                    guard case .sendOperation(let result) = results[0] else {
                        throw V2MessageOperationValidationError.invalidReceipt
                    }
                    return result
                }())
                let conflicting = try command(firstID, "different immutable payload")
                let changed = try V2MessageSendOperationRecoveryRequest(identity: conflicting.identity,
                    fingerprint: conflicting.fingerprint, domainFingerprint: conflicting.command.fingerprint)
                #expect(try await replayStore.recover(changed, token: token) == .fingerprintConflict)
            }
            try await assertRetiredDirectAuthorizationSchemaAbsent(on: sql)

        }
    }

    @Test("current preparation rejects missing policy configuration without database writes")
    func currentPolicyPreparationRequiresExplicitBinding() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let store = PostgresV2MessageSendOperationStore(database: database,
                writes: PostgresV2RoomWriteStore(database: database, contentReviewMode: .disabled), clock: { now })
            let command = try V2MessageSendOperationCommand(command: .init(roomID: roomID,
                senderUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "explicit policy binding",
                limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)
            try await withRoomActivation(database: database, roomID: roomID) { token async throws in
                await #expect(throws: V2ActorContractError.invalidConfiguration("message policy preparation required")) {
                    try await store.readOwnerPreparationInputs([
                        .init(commands: [command], token: token, deadline: .now + .seconds(5))
                    ], now: { now })
                }
                #expect(try await count("im_v2.messages", on: sql) == 0)
                #expect(try await count("im_v2.message_send_completions", on: sql) == 0)
                #expect(try await count("pg_catalog.pg_class WHERE oid=to_regclass('im_v2.direct_authorization_intents')", on: sql) == 0)
            }
        }
    }

    @Test("current room sends complete while legacy account and operation locks remain held")
    func currentPolicySendDoesNotAcquireLegacyLocks() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let operation = UUID()
            let command = try V2MessageSendOperationCommand(command: .init(roomID: roomID,
                senderUserID: senderID, clientMessageID: .init(uuid: operation), text: "no legacy locks",
                limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)
            let gate = OperationLockTestGate()
            let holder = Task {
                try await database.transaction { transaction in
                    guard let holderSQL = transaction as? any SQLDatabase else {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                    try await holderSQL.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "account-state:" + senderUUID.uuidString), 0))").run()
                    try await holderSQL.raw("""
                        SELECT pg_advisory_xact_lock(hashtextextended(
                            'v2-message-operation:' || \(bind: roomUUID)::text || ':' || \(bind: senderUUID)::text || ':' || \(bind: operation)::text, 0))
                        """).run()
                    let backend = try #require(try await holderSQL.raw("SELECT pg_backend_pid() AS pid").first(decoding: OperationLockPID.self))
                    await gate.hold(backend.pid)
                }
            }
            let holderPID = await gate.waitUntilHeld()
            do {
                let policies = v2FixtureRoomPolicyAuthorizations(database: database)
                let store = PostgresV2MessageSendOperationStore(database: database,
                    writes: PostgresV2RoomWriteStore(database: database, contentReviewMode: .disabled)
                        .usingPolicyAuthorizations(policies), clock: { now })
                try await withRoomActivation(database: database, roomID: roomID) { token in
                    let results = try await V2RoomSQLDeadline.withDeadline(.now + .seconds(3)) {
                        let prepared = try await policies.fixtureSendPreparation(store: store, now: { now })(
                            [command], token, .now + .seconds(3))
                        return try await store.executePreparedSendBatch(prepared, capacityProfile: profile,
                            identifiers: .init(), now: { now })
                    }
                    guard case .sendOperation(.receipt(let receipt))? = results.first,
                          case .accepted = receipt.outcome else { throw V2MessageOperationValidationError.invalidReceipt }
                    #expect(try await sql.raw("SELECT count(*) AS count FROM pg_locks WHERE locktype='advisory' AND granted AND pid=\(bind: holderPID)").first(decoding: OperationLockCount.self)?.count == 2)
                    #expect(try await count("im_v2.messages", on: sql) == 1)
                    #expect(try await count("pg_catalog.pg_class WHERE oid=to_regclass('im_v2.direct_authorization_intents')", on: sql) == 0)
                }
                await gate.release()
                try await holder.value
            } catch {
                await gate.release()
                _ = await holder.result
                throw error
            }
        }
    }
}

private actor OperationLockTestGate {
    private var heldPID: Int32?
    private var heldContinuation: CheckedContinuation<Int32, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func hold(_ pid: Int32) async {
        heldPID = pid
        heldContinuation?.resume(returning: pid)
        heldContinuation = nil
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilHeld() async -> Int32 {
        if let heldPID { return heldPID }
        return await withCheckedContinuation { heldContinuation = $0 }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private struct OperationLockPID: Decodable { let pid: Int32 }
private struct OperationLockCount: Decodable { let count: Int64 }
