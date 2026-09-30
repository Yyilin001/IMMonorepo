@testable import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2ServerInfrastructure
import SQLKit
import Synchronization
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("durable send batch isolates invalid content and preserves neighbouring receipts",
          arguments: [(false, "reply"), (true, "reply"), (false, "mention"),
                      (true, "mention"), (false, "media"), (true, "media")])
    func durableSendBatchIsolatesContentFailure(scenario: (Bool, String)) async throws {
        let (direct, invalidKind) = scenario
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let operationRoom = direct ? RoomID(uuid: UUID()) : roomID
            if direct {
                _ = try await V2DirectRoomOperationTestFixture(database: database, capacityProfile: profile,
                    roomShardID: "room-a", roomID: operationRoom, now: { now }).openedIdentity(
                        actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: .init(uuid: memberTwoUUID),
                        firstSubmissionDeadlineMilliseconds: 1_750_000_600_000)
            }
            let observer = BatchIsolationMessageObserver()
            let writes = PostgresV2RoomWriteStore(database: database,
                strangerMessagePolicy: try .init(maximumMessagesPerWindow: 100, window: 86_400),
                contentReviewMode: .disabled).usingControlDatabase(database)
            let store = PostgresV2MessageSendOperationStore(database: database, writes: writes,
                clock: { now }, committedMessageObserver: observer)
            func valid(_ text: String) throws -> V2MessageSendOperationCommand {
                try .init(command: .init(roomID: operationRoom, senderUserID: senderID,
                    clientMessageID: .init(uuid: UUID()), text: text, limits: .init(maxUTF8Bytes: 64)),
                    firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)
            }
            // A different member's bad content must not affect either sender's
            // other operations, including an already committed acceptance.
            let invalid = try V2MessageSendOperationCommand(command: .init(roomID: operationRoom,
                senderUserID: .init(uuid: memberTwoUUID), clientMessageID: .init(uuid: UUID()), text: "invalid",
                media: invalidKind == "media" ? [.init(mediaID: .init(uuid: UUID()))] : [],
                mentions: invalidKind == "mention" ? [.user(.init(uuid: UUID()))] : [],
                replyTo: invalidKind == "reply" ? .init(messageID: .init(uuid: UUID())) : nil,
                limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)
            let replay = try valid("original"), before = try valid("before"), after = try valid("after")
            try await withRoomActivation(database: database, roomID: operationRoom) { token in
                let executor = try V2RoomMessagingExecutor(token: token, writes: writes,
                    capacityProfile: profile, limits: .init(maxUTF8Bytes: 64), maximumEditBytes: 64,
                    now: { now }, sendOperations: store)
                let original = try await store.send(replay, token: token, capacityProfile: profile,
                    identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID())))
                let batch = [replay, before, invalid, after, invalid]
                let results = try await executor.executeSendOperationBatch(batch)
                #expect(results.count == batch.count)
                #expect(results[0] == .sendOperation(original))
                var roomSequences: [UInt64] = []
                for index in [0, 1, 3] {
                    guard case .sendOperation(.receipt(let receipt)) = results[index],
                          case .accepted(let acceptance) = receipt.outcome else {
                        Issue.record("Valid send did not retain its acceptance: \(results[index])")
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                    roomSequences.append(acceptance.roomSequence)
                }
                #expect(roomSequences == [1, 2, 3])
                guard case .sendOperation(.receipt(let rejection)) = results[2] else {
                    Issue.record("Invalid content did not produce its own durable rejection: \(results[2])")
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                #expect(rejection.outcome == .rejected(invalidKind == "mention" ? .permissionDenied : .invalidContent))
                #expect(rejection.validates(identity: try invalid.identity, fingerprint: try invalid.fingerprint))
                #expect(results[4] == results[2])
                #expect(try await store.send(invalid, token: token, capacityProfile: profile,
                    identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID()))) == .receipt(rejection))
                let recovery = try V2MessageSendOperationRecoveryRequest(identity: invalid.identity,
                    fingerprint: invalid.fingerprint, domainFingerprint: invalid.command.fingerprint, action: .closeIfAbsent)
                #expect(try await store.recover(recovery, token: token) == .receipt(rejection))
                #expect(try await executor.executeSendOperationBatch(batch) == results)
            }
            #expect(try await count("im_v2.messages", on: sql) == 3)
            #expect(try await count("im_v2.message_send_completions", on: sql) == 3)
            #expect(try await count("im_v2.message_send_operation_receipts", on: sql) == 4)
            #expect(try await count("im_v2.message_operation_closures", on: sql) == 1)
            #expect(observer.operations == [replay.command.clientMessageID, before.command.clientMessageID, after.command.clientMessageID])
            let used = try #require(try await sql.raw("""
                SELECT command_window_used AS used FROM im_v2.shard_admission_pools
                WHERE room_shard_id='room-a' AND capacity_profile_id=\(bind: profile.id)
                """).first(decoding: BatchIsolationShardUsage.self))
            #expect(used.used == 3)
        }
    }

    @Test("durable send content rejection survives batch admission rollback atomically",
          arguments: [false, true])
    func durableSendBatchContentFailureRecovery(receiptWriteFails: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let observer = BatchIsolationMessageObserver()
            let writes = PostgresV2RoomWriteStore(database: database, contentReviewMode: .disabled)
            let store = PostgresV2MessageSendOperationStore(database: database, writes: writes,
                clock: { now }, committedMessageObserver: observer)
            let valid = try V2MessageSendOperationCommand(command: .init(roomID: roomID,
                senderUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "valid",
                limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)
            let invalid = try V2MessageSendOperationCommand(command: .init(roomID: roomID,
                senderUserID: .init(uuid: memberTwoUUID), clientMessageID: .init(uuid: UUID()), text: "bad reply",
                replyTo: .init(messageID: .init(uuid: UUID())), limits: .init(maxUTF8Bytes: 64)),
                firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)
            if receiptWriteFails {
                // Fail after the valid command's provisional writes, rather
                // than replacing a database failure with a content rejection.
                try await sql.raw("""
                    CREATE FUNCTION im_v2.isolation_fail_receipt() RETURNS trigger LANGUAGE plpgsql AS $$
                    BEGIN
                        IF NEW.operation_id = '\(unsafeRaw: invalid.command.clientMessageID.rawValue)'::uuid THEN
                            RAISE EXCEPTION 'receipt write failed' USING ERRCODE='23514';
                        END IF;
                        RETURN NEW;
                    END $$
                    """).run()
                try await sql.raw("CREATE TRIGGER isolation_fail_receipt BEFORE INSERT ON im_v2.message_send_operation_receipts FOR EACH ROW EXECUTE FUNCTION im_v2.isolation_fail_receipt()").run()
            } else {
                try await sql.raw("CREATE FUNCTION im_v2.isolation_reject_tail() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NULL; END $$").run()
                try await sql.raw("CREATE TRIGGER isolation_reject_tail BEFORE UPDATE OF command_window_used ON im_v2.shard_admission_pools FOR EACH ROW EXECUTE FUNCTION im_v2.isolation_reject_tail()").run()
            }
            try await withRoomActivation(database: database, roomID: roomID) { token in
                let executor = try V2RoomMessagingExecutor(token: token, writes: writes,
                    capacityProfile: profile, limits: .init(maxUTF8Bytes: 64), maximumEditBytes: 64,
                    now: { now }, sendOperations: store)
                let batch = [valid, invalid, invalid]
                if receiptWriteFails {
                    await #expect(throws: (any Error).self) {
                        _ = try await executor.executeSendOperationBatch(batch)
                    }
                } else {
                    let results = try await executor.executeSendOperationBatch(batch)
                    guard case .sendOperation(.deferred(let hint)) = results[0],
                          case .sendOperation(.receipt(let rejection)) = results[1] else {
                        Issue.record("Unexpected admission recovery: \(results)")
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                    #expect(hint.reason == .rateLimited)
                    #expect(rejection.outcome == .rejected(.invalidContent))
                    #expect(results[2] == results[1])
                    let query = try V2MessageSendOperationRecoveryRequest(identity: valid.identity,
                        fingerprint: valid.fingerprint, domainFingerprint: valid.command.fingerprint, action: .query)
                    #expect(try await store.recover(query, token: token) == .unresolved)
                    #expect(try await store.send(invalid, token: token, capacityProfile: profile,
                        identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID()))) == .receipt(rejection))
                }
            }
            for table in ["messages", "message_send_completions", "room_events", "message_projection_states"] {
                #expect(try await count("im_v2.\(table)", on: sql) == 0)
            }
            #expect(try await count("im_v2.message_send_operation_receipts", on: sql) == (receiptWriteFails ? 0 : 1))
            #expect(try await count("im_v2.message_operation_closures", on: sql) == (receiptWriteFails ? 0 : 1))
            #expect(observer.operations.isEmpty)
        }
    }

    @Test("durable send batch propagates a shared configuration failure")
    func durableSendBatchPropagatesSharedStoreFailure() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let writes = PostgresV2RoomWriteStore(database: database, contentReviewMode: .disabled)
            let store = PostgresV2MessageSendOperationStore(database: database, writes: writes, clock: { now })
            let command = try V2MessageSendOperationCommand(command: .init(roomID: roomID,
                senderUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "valid",
                limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)
            try await withRoomActivation(database: database, roomID: roomID) { token in
                let executor = try V2RoomMessagingExecutor(token: token, writes: writes,
                    capacityProfile: .init(id: "wrong-deployment-profile", limits: profile.limits),
                    limits: .init(maxUTF8Bytes: 64), maximumEditBytes: 64, now: { now }, sendOperations: store)
                await #expect(throws: V2RoomWriteStoreError.capacityProfileMismatch) {
                    _ = try await executor.executeSendOperationBatch([command, command])
                }
            }
            #expect(try await count("im_v2.message_send_operation_receipts", on: sql) == 0)
            #expect(try await count("im_v2.message_operation_closures", on: sql) == 0)
            #expect(try await count("im_v2.messages", on: sql) == 0)
        }
    }
}

private struct BatchIsolationShardUsage: Decodable { let used: Int64 }

private final class BatchIsolationMessageObserver: V2CommittedMessageBatchObserving, Sendable {
    private let recorded = Mutex<[ClientMessageID]>([])
    var operations: [ClientMessageID] { recorded.withLock { $0 } }
    func observeCommittedMessages(_ outcomes: [V2SendMessageOutcome]) {
        recorded.withLock { operations in
            for outcome in outcomes {
                if case .accepted(let message) = outcome { operations.append(message.clientMessageID) }
            }
        }
    }
}
