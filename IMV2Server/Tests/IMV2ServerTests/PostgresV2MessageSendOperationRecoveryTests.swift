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
            #expect(try await count("pg_catalog.pg_class WHERE oid=to_regclass('im_v2.direct_authorization_intents')", on: sql) == 0)
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
            @Sendable func command(_ text: String, id: ClientMessageID) throws -> V2MessageSendOperationCommand {
                try .init(command: .init(roomID: roomID, senderUserID: senderID,
                    clientMessageID: id, text: text, limits: .init(maxUTF8Bytes: 64)),
                    firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)
            }
            let first = try command("first", id: operation), changed = try command("changed", id: operation)
            try await withRoomActivation(database: database, roomID: roomID) { token in
                await #expect(throws: V2RoomCallFailure.rolledBack(.unavailable)) {
                    try await store.sendBatch([first, command("fresh tail", id: .init(uuid: UUID()))], token: token,
                        capacityProfile: profile, identifiers: .init(), now: { now })
                }
                for table in ["messages", "message_send_completions"] {
                    #expect(try await count("im_v2.\(table)", on: sql) == 0)
                }
                let query = try V2MessageSendOperationRecoveryRequest(identity: changed.identity,
                    fingerprint: changed.fingerprint, domainFingerprint: changed.command.fingerprint)
                #expect(try await store.recover(query, token: token) == .unresolved)
                try await sql.raw("DROP TRIGGER recovery_reject_tail ON im_v2.messages").run()
                guard case .receipt(let accepted) = try await store.send(changed, token: token,
                    capacityProfile: profile, identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID()))),
                      case .accepted = accepted.outcome else { throw V2RoomWriteStoreError.corruptPersistenceState }
                try await sql.raw("CREATE TRIGGER recovery_reject_tail BEFORE INSERT ON im_v2.messages FOR EACH ROW EXECUTE FUNCTION im_v2.recovery_reject_tail()").run()
                await #expect(throws: V2RoomCallFailure.rolledBack(.unavailable)) {
                    try await store.sendBatch([command("fresh", id: .init(uuid: UUID())), first],
                        token: token, capacityProfile: profile, identifiers: .init(), now: { now })
                }
                #expect(try await store.send(first, token: token, capacityProfile: profile,
                    identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID()))) == .fingerprintConflict)
                #expect(try await store.recover(query, token: token) == .receipt(accepted))
                #expect(try await count("im_v2.message_send_completions", on: sql) == 1)
            }
        }
    }

    @Test("operation policy denial keeps one private hint per identity without a durable rejection result")
    func durableSendBatchRestoresDirectDenial() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000), profile = try forwardImportTestProfile()
            let direct = try await V2DirectRoomOperationTestFixture(database: database, capacityProfile: profile,
                roomShardID: "room-a", roomID: .init(uuid: UUID()), now: { now }).openedIdentity(
                    actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: .init(uuid: memberTwoUUID),
                    firstSubmissionDeadlineMilliseconds: 1_750_000_600_000)
            try await sql.raw("INSERT INTO im_v2.user_stranger_message_preferences(user_id,allows_stranger_messages,updated_at) VALUES(\(bind:memberTwoUUID),false,\(bind:now)) ON CONFLICT(user_id) DO UPDATE SET allows_stranger_messages=false,updated_at=EXCLUDED.updated_at").run()
            let store = try recoveryTestStore(database: database, now: now)
            let denied = try V2MessageSendOperationCommand(command: .init(roomID: direct.roomID,
                senderUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "denied",
                limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)
            let initialOutbox = try await count("im_v2.user_state_event_outbox", on: sql)
            let initialTimeline = try await count("im_v2.room_timeline_activities", on: sql)
            try await withRoomActivation(database: database, roomID: direct.roomID) { token in
                let results = try await store.sendBatch([denied, denied], token: token,
                    capacityProfile: profile, identifiers: .init(), now: { now })
                for result in results {
                    guard case .sendOperation(.receipt(let rejection)) = result else {
                        throw V2MessageOperationValidationError.invalidReceipt
                    }
                    #expect(rejection.outcome == .rejected(.directPolicyDenied))
                }
                let query = try V2MessageSendOperationRecoveryRequest(identity: denied.identity,
                    fingerprint: denied.fingerprint, domainFingerprint: denied.command.fingerprint)
                #expect(try await store.recover(query, token: token) == .unresolved)
                // A fresh message produces a fresh sender-only hint. Retrying
                // the original identity above did not duplicate its hint.
                let another = try V2MessageSendOperationCommand(command: .init(roomID: direct.roomID,
                    senderUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "still denied",
                    limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)
                guard case .receipt(let rejection) = try await store.send(another, token: token,
                    capacityProfile: profile, identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID()))) else {
                    throw V2MessageOperationValidationError.invalidReceipt
                }
                #expect(rejection.outcome == .rejected(.directPolicyDenied))
            }
            for table in ["messages", "message_send_completions"] {
                #expect(try await count("im_v2.\(table)", on: sql) == 0)
            }
            #expect(try await count("im_v2.user_state_event_outbox", on: sql) == initialOutbox + 3)
            #expect(try await count("im_v2.room_timeline_activities", on: sql) == initialTimeline + 2)
            #expect(try await count("im_v2.room_timeline_activities WHERE activity_type='direct_message_restricted' AND recipient_user_id='\(senderUUID.uuidString)'", on: sql) == 2)
            #expect(try await count("im_v2.room_timeline_activities WHERE activity_type='direct_message_restricted' AND recipient_user_id='\(memberTwoUUID.uuidString)'", on: sql) == 0)
        }
    }

    @Test("conflicting preparation creates no reservation and an uncommitted identity remains reusable")
    func durableSendBatchUncommittedIdentityRemainsReusable() async throws {
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
                await #expect(throws: V2PolicyAuthorizationLifecycleError.identityConflict) {
                    try await store.sendBatch([first, changed], token: token,
                        capacityProfile: profile, identifiers: .init(), now: { now })
                }
                #expect(try await count("im_v2.messages", on: sql) == 0)
                #expect(try await count("pg_catalog.pg_class WHERE oid=to_regclass('im_v2.direct_authorization_intents')", on: sql) == 0)
                try await sql.raw("DROP TRIGGER recovery_reject_tail ON im_v2.messages").run()
                let changedResult = try await store.send(changed, token: token, capacityProfile: profile,
                    identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID())))
                guard case .receipt(let receipt) = changedResult, case .accepted = receipt.outcome else {
                    throw V2MessageOperationValidationError.invalidReceipt
                }
            }
            try await assertRetiredDirectAuthorizationSchemaAbsent(on: sql)
            #expect(try await count("im_v2.message_send_completions", on: sql) == 1)
        }
    }

    private func recoveryTestStore(database: any Database, now: Date) throws -> PostgresV2MessageSendOperationStore {
        v2FixtureMessageSendOperationStore(database: database, writes: PostgresV2RoomWriteStore(database: database,
            strangerMessagePolicy: try .init(maximumMessagesPerWindow: 100, window: 86_400),
            contentReviewMode: .disabled).usingControlDatabase(database), clock: { now })
    }

    private func installRecoveryTailFailure(on sql: any SQLDatabase) async throws {
        try await sql.raw("CREATE FUNCTION im_v2.recovery_reject_tail() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'injected message persistence lock failure' USING ERRCODE='55P03'; END $$").run()
        try await sql.raw("CREATE TRIGGER recovery_reject_tail BEFORE INSERT ON im_v2.messages FOR EACH ROW EXECUTE FUNCTION im_v2.recovery_reject_tail()").run()
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
