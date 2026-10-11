@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit
import Testing

@testable import IMV2Server
@testable import IMV2ServerInfrastructure

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test(
        "Room-owned preferences retain original receipts, close atomically and fence stale intents",
        arguments: [false, true])
    func personalPreferenceRecovery(favorite: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, userDatabase, sql, userSQL, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let send = try V2SendMessageService(
                store: V2PolicyAuthorizedTestWriteStore(database: database, controlDatabase: database,
                    store: PostgresV2RoomWriteStore(database: database), shardID: "room-a", epoch: 0), capacityProfile: forwardImportTestProfile(),
                limits: .init(maxUTF8Bytes: 64), now: { now })
            guard
                case .accepted(let message) = try await send.send(
                    .init(
                        roomID: roomID, actorUserID: senderID, clientMessageID: .init(uuid: UUID()),
                        text: "favorite receipt fixture"))
            else { throw CancellationError() }
            let leases = PostgresV2RoomActivationStore(database: database)
            let owner = try V2RoomDataOwner(shardID: "room-a", epoch: 0)
            let host = V2ActorHostIdentity(hostID: try .init("preference-host"), incarnationID: UUID())
            guard
                case .acquired(let lease) = try await leases.acquire(
                    roomID: roomID, owner: owner, host: host, duration: try .init(30_000))
            else { throw V2RoomActivationLeaseError.activationChanged }
            let service = PostgresV2ConversationCapabilitiesStore(
                database: database, activationScope: try .init(tokens: [lease.token]))
            func command(_ operation: UUID, revision: UInt64, desired: Bool, deadline: UInt64 = UInt64(Int64.max))
                throws -> (
                    V2OperationIdentity, V2OperationFingerprint,
                    @Sendable () async throws -> V2PersonalPreferenceReceipt
                )
            {
                let expected = try #require(V2PersonalPreferenceRevision(rawValue: revision))
                if favorite {
                    let value = try V2MessageFavoriteCommand(
                        operationID: .init(uuid: operation), roomID: roomID, messageID: message.messageID,
                        isFavorited: desired, expectedRevision: expected, firstSubmissionDeadlineMilliseconds: deadline)
                    return (
                        try value.identity(actorUserID: senderID), try value.fingerprint(actorUserID: senderID),
                        { try await service.setMessageFavorite(actorUserID: senderID, command: value, now: now) }
                    )
                }
                let value = try V2ConversationStateCommand(
                    operationID: .init(uuid: operation), roomID: roomID, isPinned: desired, isArchived: desired,
                    muteUntil: nil, expectedRevision: expected, firstSubmissionDeadlineMilliseconds: deadline)
                return (
                    try value.identity(actorUserID: senderID), try value.fingerprint(actorUserID: senderID),
                    { try await service.setConversationState(actorUserID: senderID, command: value, now: now) }
                )
            }
            let priorOutbox = try await count("im_v2.user_state_event_outbox", on: sql)
            let a = try command(UUID(), revision: 0, desired: true)
            #expect(
                try await service.recover(
                    actorUserID: senderID, request: .init(identity: a.0, fingerprint: a.1, action: .query), now: now)
                    == .unresolved)
            let receiptA = try await a.2()
            guard case .committed = receiptA.outcome else { throw CancellationError() }
            let changed = try command(
                try #require(UUID(uuidString: a.0.operation.rawOperationID)), revision: 0, desired: false)
            await #expect(throws: V2ConversationCapabilitiesStoreError.operationPayloadMismatch) {
                _ = try await changed.2()
            }
            let b = try command(UUID(), revision: 1, desired: false)
            let receiptB = try await b.2()
            guard case .committed = receiptB.outcome else { throw CancellationError() }
            #expect(try await a.2() == receiptA)
            #expect(
                try await service.recover(
                    actorUserID: senderID, request: .init(identity: a.0, fingerprint: a.1, action: .closeIfAbsent),
                    now: now) == .receipt(receiptA))
            let stale = try command(UUID(), revision: 0, desired: true)
            let staleReceipt = try await stale.2()
            #expect(staleReceipt.outcome == .rejected(.revisionConflict(current: .init(rawValue: 2)!)))
            #expect(try await stale.2() == staleReceipt)
            let expired = try command(UUID(), revision: 2, desired: true, deadline: 1)
            #expect(try await expired.2().outcome == .rejected(.expiredUnsubmitted))
            let closed = try command(UUID(), revision: 2, desired: true)
            let close = try await service.recover(
                actorUserID: senderID,
                request: .init(identity: closed.0, fingerprint: closed.1, action: .closeIfAbsent), now: now)
            guard case .receipt(let closure) = close else { throw CancellationError() }
            #expect(closure.outcome == .closed)
            #expect(try await closed.2() == closure)
            let conflict = try V2OperationFingerprint(version: 1, digest: Data(repeating: 7, count: 32))
            #expect(
                try await service.recover(
                    actorUserID: senderID, request: .init(identity: a.0, fingerprint: conflict, action: .query),
                    now: now) == .fingerprintConflict)
            // No later projection can resurrect the canceled desired state: false has revision two.
            let table = favorite ? "user_message_favorites" : "user_room_preferences"
            let row = try #require(
                try await sql.raw(
                    "SELECT revision AS value FROM im_v2.\(unsafeRaw:table) WHERE user_id=\(bind:senderUUID)"
                ).first(decoding: PreferenceTestRevision.self))
            #expect(row.value == 2)
            #expect(try await count("im_v2.user_state_event_outbox", on: sql) == priorOutbox + 2)
            #expect(try await count("im_v2.personal_preference_operation_receipts", on: sql) == 5)
            // Deliver later B before A to a distinct user database. The snapshot keeps B's
            // false state and revision, including after a reset rebuild.
            let projector = try PostgresV2UserStateEventProjector(database: userDatabase)
            let desiredKind: V2UserStateEventKind = favorite ? .messageFavorite : .conversationState
            let events = try await frozenUserStateEvents(on: sql, userID: senderUUID, kind: desiredKind)
            #expect(events.count == 2)
            let deliveredRevisions = try events.map {
                let payload = try #require(JSONSerialization.jsonObject(with: Data($0.payloadJSON.utf8)) as? [String: Any])
                return try #require(payload["revision"] as? Int)
            }
            #expect(deliveredRevisions == [2, 1])
            for event in events {
                let sequence = try await projector.project(event)
                #expect(try await projector.project(event) == sequence)
            }
            let worker = PostgresV2UserProjectionWorker(database: userDatabase)
            let report = try await worker.runOnce(now: Date().addingTimeInterval(2))
            #expect(report.failedRecordCount == 0)
            let snapshot = try #require(
                try await userSQL.raw(
                    "SELECT (payload->>'revision')::bigint AS value FROM im_v2.user_projection_versions WHERE user_id=\(bind:senderUUID) AND projection_kind=\(bind:desiredKind.rawValue) AND valid_to_sequence IS NULL"
                ).first(decoding: PreferenceTestRevision.self))
            #expect(snapshot.value == 2)
            for _ in 0..<8 {
                let racing = try command(UUID(), revision: 2, desired: true)
                async let submitted = racing.2()
                async let recovery = service.recover(
                    actorUserID: senderID,
                    request: .init(identity: racing.0, fingerprint: racing.1, action: .closeIfAbsent), now: now)
                let (submit, recover) = try await (submitted, recovery)
                #expect(recover == .receipt(submit))
                switch submit.outcome {
                case .closed: break
                case .committed: break
                case .rejected(.revisionConflict): break
                default: Issue.record("unexpected race outcome")
                }
            }
            #expect(try await leases.release(token: lease.token))
            await #expect(throws: V2RoomActivationLeaseError.activationChanged) {
                _ = try await service.recover(
                    actorUserID: senderID, request: .init(identity: a.0, fingerprint: a.1, action: .query), now: now)
            }
            // Permanent receipts cannot be mutated or deleted through ordinary SQL.
            await #expect(throws: (any Error).self) {
                try await sql.raw("DELETE FROM im_v2.personal_preference_operation_receipts").run()
            }
            await #expect(throws: (any Error).self) {
                try await sql.raw("UPDATE im_v2.personal_preference_operation_receipts SET outcome_kind='closed'").run()
            }
        }
    }
}
private struct PreferenceTestRevision: Decodable { let value: Int64 }
