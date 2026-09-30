@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit
import Testing
@testable import IMV2ServerInfrastructure
@testable import IMV2ServerGateway

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("durable send rejects opaque persistence IDs before querying or reserving authorization", arguments: [false, true])
    func durableSendRejectsNonUUIDPersistenceIDs(invalidActor: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let direct = try await V2DirectRoomOperationTestFixture(database: database, capacityProfile: profile,
                roomShardID: "room-a", roomID: .init(uuid: UUID()), now: { now }).openedIdentity(
                    actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: .init(uuid: memberTwoUUID),
                    firstSubmissionDeadlineMilliseconds: 1_750_000_600_000)
            let store = try recoveryTestStore(database: database, now: now)
            let invalid = try V2MessageSendOperationCommand(command: .init(roomID: direct.roomID,
                senderUserID: invalidActor ? .init("opaque-actor") : senderID,
                clientMessageID: invalidActor ? .init(uuid: UUID()) : .init("not-a-uuid"),
                text: "invalid persistence ID", limits: .init(maxUTF8Bytes: 64)),
                firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)
            let http = try JSONDecoder().decode(V2MessageSendOperationCommand.self, from: JSONEncoder().encode(invalid))
            let gateway = try V2MessageSendOperationWireCodec.decode(command: V2MessageSendOperationWireCodec.encode(command: invalid))
            #expect(http == invalid && gateway == invalid)
            let valid = try V2MessageSendOperationCommand(command: .init(roomID: direct.roomID,
                senderUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "valid",
                limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)
            try await withRoomActivation(database: database, roomID: direct.roomID) { token in
                for command in [http, gateway] {
                    await #expect(throws: V2RoomCallFailure.notAccepted(.invalidRequest)) {
                        _ = try await store.send(command, token: token, capacityProfile: profile,
                            identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID())))
                    }
                }
                await #expect(throws: V2RoomCallFailure.notAccepted(.invalidRequest)) {
                    _ = try await store.sendBatch([valid, invalid], token: token, capacityProfile: profile,
                        identifiers: .init(), now: { now })
                }
            }
            #expect(try await count("im_v2.direct_authorization_intents", on: sql) == 0)
            #expect(try await count("im_v2.message_send_operation_receipts", on: sql) == 0)
            #expect(try await count("im_v2.message_send_completions", on: sql) == 0)
        }
    }

    @Test("batch rollback recomputes fingerprint conflicts and retains committed conflicts")
    func durableSendBatchRechecksRolledBackFingerprintConflict() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let store = try recoveryTestStore(database: database, now: now)
            try await installRecoveryTailFailure(on: sql)
            let operation = ClientMessageID(uuid: UUID())
            func command(_ text: String, id: ClientMessageID) throws -> V2MessageSendOperationCommand {
                try .init(command: .init(roomID: roomID, senderUserID: senderID,
                    clientMessageID: id, text: text, limits: .init(maxUTF8Bytes: 64)),
                    firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)
            }
            let first = try command("first", id: operation), changed = try command("changed", id: operation)
            try await withRoomActivation(database: database, roomID: roomID) { token in
                let results = try await store.sendBatch([first, changed], token: token,
                    capacityProfile: profile, identifiers: .init(), now: { now })
                #expect(results.count == 2)
                for result in results {
                    guard case .sendOperation(.deferred(let hint)) = result else {
                        Issue.record("Expected a retryable result after rollback: \(result)")
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                    #expect(hint.reason == .rateLimited)
                }
                for table in ["messages", "message_send_completions", "message_send_operation_receipts", "message_operation_closures"] {
                    #expect(try await count("im_v2.\(table)", on: sql) == 0)
                }
                let query = try V2MessageSendOperationRecoveryRequest(identity: changed.identity,
                    fingerprint: changed.fingerprint, domainFingerprint: changed.command.fingerprint, action: .query)
                #expect(try await store.recover(query, token: token) == .unresolved)
                try await sql.raw("DROP TRIGGER recovery_reject_tail ON im_v2.shard_admission_pools").run()
                guard case .receipt(let accepted) = try await store.send(changed, token: token,
                    capacityProfile: profile, identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID()))),
                      case .accepted = accepted.outcome else { throw V2RoomWriteStoreError.corruptPersistenceState }
                try await sql.raw("CREATE TRIGGER recovery_reject_tail BEFORE UPDATE OF command_window_used ON im_v2.shard_admission_pools FOR EACH ROW EXECUTE FUNCTION im_v2.recovery_reject_tail()").run()
                let failed = try await store.sendBatch([command("fresh", id: .init(uuid: UUID())), first],
                    token: token, capacityProfile: profile, identifiers: .init(), now: { now })
                guard case .sendOperation(.deferred) = failed[0] else { throw V2RoomWriteStoreError.corruptPersistenceState }
                #expect(failed[1] == .sendOperation(.fingerprintConflict))
                #expect(try await store.recover(query, token: token) == .receipt(accepted))
                #expect(try await count("im_v2.message_send_completions", on: sql) == 1)
                #expect(try await count("im_v2.message_send_operation_receipts", on: sql) == 1)
            }
        }
    }

    @Test("batch rollback restores direct denial facts atomically", arguments: ["rateLimited", "leaseChanged", "recoveryFailure"])
    func durableSendBatchRestoresDirectDenial(failure: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let direct = try await V2DirectRoomOperationTestFixture(database: database, capacityProfile: profile,
                roomShardID: "room-a", roomID: .init(uuid: UUID()), now: { now }).openedIdentity(
                    actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: .init(uuid: memberTwoUUID),
                    firstSubmissionDeadlineMilliseconds: 1_750_000_600_000)
            try await sql.raw("INSERT INTO im_v2.user_stranger_message_preferences(user_id,allows_stranger_messages,updated_at) VALUES(\(bind:memberTwoUUID),false,\(bind:now)) ON CONFLICT(user_id) DO UPDATE SET allows_stranger_messages=false,updated_at=EXCLUDED.updated_at").run()
            let store = try recoveryTestStore(database: database, now: now)
            let denied = try V2MessageSendOperationCommand(command: .init(roomID: direct.roomID,
                senderUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "denied",
                limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)
            let reverse = try V2MessageSendOperationCommand(command: .init(roomID: direct.roomID,
                senderUserID: .init(uuid: memberTwoUUID), clientMessageID: .init(uuid: UUID()), text: "accepted",
                limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)
            let leaseChanged = failure == "leaseChanged"
            if leaseChanged {
                // Change the shared lease only after the scalar reduction, so
                // admission fails at the batch tail. Rollback restores the lease.
                try await sql.raw("CREATE FUNCTION im_v2.recovery_change_lease() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN UPDATE im_v2.shard_admission_pools SET generation=generation+1 WHERE room_shard_id='room-a'; RETURN NEW; END $$").run()
                try await sql.raw("CREATE TRIGGER recovery_change_lease BEFORE INSERT ON im_v2.messages FOR EACH ROW EXECUTE FUNCTION im_v2.recovery_change_lease()").run()
            } else {
                try await installRecoveryTailFailure(on: sql)
            }
            if failure == "recoveryFailure" {
                // Sequences survive savepoint rollback, allowing failure only
                // on the second (recovery) attempt to write the denial fact.
                try await sql.raw("CREATE SEQUENCE im_v2.recovery_denial_attempts").run()
                try await sql.raw("CREATE FUNCTION im_v2.recovery_fail_denial() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF nextval('im_v2.recovery_denial_attempts') > 1 THEN RAISE EXCEPTION 'denial recovery failed' USING ERRCODE='23514'; END IF; RETURN NEW; END $$").run()
                try await sql.raw("CREATE TRIGGER recovery_fail_denial BEFORE INSERT ON im_v2.direct_message_denials FOR EACH ROW EXECUTE FUNCTION im_v2.recovery_fail_denial()").run()
                let initialOutboxCount = try await count("im_v2.user_state_event_outbox", on: sql)
                let initialTimelineCount = try await count("im_v2.room_timeline_activities", on: sql)
                try await withRoomActivation(database: database, roomID: direct.roomID) { token in
                    await #expect(throws: (any Error).self) {
                        _ = try await store.sendBatch([denied, reverse], token: token,
                            capacityProfile: profile, identifiers: .init(), now: { now })
                    }
                }
                let attempts = try await sql.raw("SELECT last_value AS count FROM im_v2.recovery_denial_attempts").first(decoding: RecoveryCount.self)
                #expect(attempts?.count == 2)
                for table in ["direct_message_denials", "direct_authorization_receipts", "message_send_operation_receipts", "message_operation_closures", "message_send_completions"] {
                    #expect(try await count("im_v2.\(table)", on: sql) == 0)
                }
                #expect(try await count("im_v2.user_state_event_outbox", on: sql) == initialOutboxCount)
                #expect(try await count("im_v2.room_timeline_activities", on: sql) == initialTimelineCount)
                return
            }
            let results = try await withRoomActivation(database: database, roomID: direct.roomID) { token in
                let results = try await store.sendBatch([denied, reverse, denied], token: token,
                    capacityProfile: profile, identifiers: .init(), now: { now })
                guard case .sendOperation(.receipt(let receipt)) = results[0],
                      case .sendOperation(.deferred(let hint)) = results[1] else {
                    Issue.record("Unexpected results: \(results)")
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                #expect(receipt.outcome == .rejected(.directPolicyDenied))
                #expect(hint.reason == (leaseChanged ? .admissionUnavailable : .rateLimited))
                #expect(results[2] == results[0])
                #expect(try await store.send(denied, token: token, capacityProfile: profile,
                    identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID()))) == .receipt(receipt))
                return results
            }
            #expect(results.count == 3)
            let fact = try #require(try await sql.raw("""
                SELECT denial.source_event_id, denial.timeline_sequence,
                       (SELECT COUNT(*) FROM im_v2.user_state_event_outbox work
                        WHERE work.source_event_id=denial.source_event_id AND work.user_id=denial.sender_user_id
                          AND work.projection_kind='timeline_activity') AS activity_count,
                       (SELECT COUNT(*) FROM im_v2.user_state_event_outbox work
                        WHERE work.source_event_id=denial.source_event_id AND work.user_id=denial.sender_user_id
                          AND work.projection_kind='direct_sending_capability') AS capability_count,
                       CASE WHEN pair.lower_user_id=denial.sender_user_id THEN pair.lower_can_send ELSE pair.higher_can_send END AS can_send
                FROM im_v2.direct_message_denials denial JOIN im_v2.direct_room_pairs pair USING(room_id)
                WHERE denial.room_id=\(bind:direct.roomID.uuidValue!) AND denial.sender_user_id=\(bind:senderUUID)
                  AND denial.client_message_id=\(bind:denied.command.clientMessageID.uuidValue!)
                """).first(decoding: RecoveredDenialFact.self))
            #expect(fact.activityCount == 1 && fact.capabilityCount == 1 && !fact.canSend)
            let timeline = try await sql.raw("SELECT count(*) AS count FROM im_v2.room_timeline_activities WHERE source_event_id=\(bind:fact.sourceEventID) AND timeline_sequence=\(bind:fact.timelineSequence)").first(decoding: RecoveryCount.self)
            #expect(timeline?.count == 1)
            #expect(try await count("im_v2.direct_message_denials", on: sql) == 1)
            #expect(try await count("im_v2.message_send_operation_receipts", on: sql) == 1)
            #expect(try await count("im_v2.message_send_completions", on: sql) == 0)
            let generation = try #require(try await sql.raw("SELECT generation AS count FROM im_v2.direct_authorization_intents WHERE room_id=\(bind:direct.roomID.uuidValue!) AND sender_user_id=\(bind:senderUUID) AND client_message_id=\(bind:denied.command.clientMessageID.uuidValue!)").first(decoding: RecoveryCount.self)).count
            let attempt = V2DirectAuthorizationAttempt(roomID: direct.roomID.uuidValue!, senderID: senderUUID,
                clientMessageID: denied.command.clientMessageID.uuidValue!, generation: generation,
                recipientID: memberTwoUUID, ownerShardID: "room-a", ownerEpoch: 0, fingerprint: denied.command.fingerprint.digest)
            let proof = try await PostgresV2DirectAuthorizationReceiptStore().committedReceipt(attempt, database: database)
            #expect(proof?.disposition == .denied && proof?.eventID == fact.sourceEventID)
        }
    }

    @Test("batch rollback retains a conflict backed by the committed control intent")
    func durableSendBatchRetainsControlIntentConflict() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let direct = try await V2DirectRoomOperationTestFixture(database: database, capacityProfile: profile,
                roomShardID: "room-a", roomID: .init(uuid: UUID()), now: { now }).openedIdentity(
                    actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: .init(uuid: memberTwoUUID),
                    firstSubmissionDeadlineMilliseconds: 1_750_000_600_000)
            let store = try recoveryTestStore(database: database, now: now)
            try await installRecoveryTailFailure(on: sql)
            let operation = ClientMessageID(uuid: UUID())
            func command(_ text: String) throws -> V2MessageSendOperationCommand {
                try .init(command: .init(roomID: direct.roomID, senderUserID: senderID,
                    clientMessageID: operation, text: text, limits: .init(maxUTF8Bytes: 64)),
                    firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)
            }
            let first = try command("first"), changed = try command("changed")
            try await withRoomActivation(database: database, roomID: direct.roomID) { token in
                let results = try await store.sendBatch([first, changed], token: token,
                    capacityProfile: profile, identifiers: .init(), now: { now })
                guard case .sendOperation(.deferred) = results[0] else { throw V2RoomWriteStoreError.corruptPersistenceState }
                #expect(results[1] == .sendOperation(.fingerprintConflict))
                #expect(try await store.send(changed, token: token, capacityProfile: profile,
                    identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID()))) == .fingerprintConflict)
            }
            let intent = try await sql.raw("SELECT count(*) AS count FROM im_v2.direct_authorization_intents WHERE room_id=\(bind:direct.roomID.uuidValue!) AND sender_user_id=\(bind:senderUUID) AND client_message_id=\(bind:operation.uuidValue!) AND request_fingerprint=\(bind:first.command.fingerprint.digest)").first(decoding: RecoveryCount.self)
            #expect(intent?.count == 1)
            #expect(try await count("im_v2.message_send_operation_receipts", on: sql) == 0)
            #expect(try await count("im_v2.message_send_completions", on: sql) == 0)
        }
    }

    private func recoveryTestStore(database: any Database, now: Date) throws -> PostgresV2MessageSendOperationStore {
        .init(database: database, writes: PostgresV2RoomWriteStore(database: database,
            strangerMessagePolicy: try .init(maximumMessagesPerWindow: 100, window: 86_400),
            contentReviewMode: .disabled).usingControlDatabase(database), clock: { now })
    }

    private func installRecoveryTailFailure(on sql: any SQLDatabase) async throws {
        try await sql.raw("CREATE FUNCTION im_v2.recovery_reject_tail() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NULL; END $$").run()
        try await sql.raw("CREATE TRIGGER recovery_reject_tail BEFORE UPDATE OF command_window_used ON im_v2.shard_admission_pools FOR EACH ROW EXECUTE FUNCTION im_v2.recovery_reject_tail()").run()
    }
}

private struct RecoveryCount: Decodable { let count: Int64 }
private struct RecoveredDenialFact: Decodable {
    let sourceEventID: UUID
    let timelineSequence: Int64
    let activityCount: Int64
    let capabilityCount: Int64
    let canSend: Bool
    enum CodingKeys: String, CodingKey {
        case sourceEventID = "source_event_id", timelineSequence = "timeline_sequence"
        case activityCount = "activity_count", capabilityCount = "capability_count", canSend = "can_send"
    }
}
