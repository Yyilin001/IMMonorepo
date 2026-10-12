@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
@testable import IMV2ServerInfrastructure
import Foundation
import IMV2Core
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("send success survives a new store; rejected identities can be retried with new input")
    func sendSuccessOnlyRecoveryAndRejectedRetry() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000.123)
            let profile = try forwardImportTestProfile()
            let operation = ClientMessageID(uuid: UUID())
            let store = v2FixtureMessageSendOperationStore(database: database,
                writes: PostgresV2RoomWriteStore(database: database), clock: { now })
            let expired = try V2MessageSendOperationCommand(command: .init(roomID: roomID,
                senderUserID: senderID, clientMessageID: operation, text: "expired input",
                limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: 1_749_999_999_000)
            @Sendable func query(_ command: V2MessageSendOperationCommand) throws -> V2MessageSendOperationRecoveryRequest {
                try .init(identity: command.identity, fingerprint: command.fingerprint,
                    domainFingerprint: command.command.fingerprint)
            }
            try await withRoomActivation(database: database, roomID: roomID) { token in
                guard case .receipt(let rejection) = try await store.send(expired, token: token,
                    capacityProfile: profile, identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID()))) else {
                    throw V2MessageOperationValidationError.invalidReceipt
                }
                #expect(rejection.outcome == .rejected(.expiredUnsubmitted))
                #expect(try await store.recover(query(expired), token: token) == .unresolved)
                #expect(try await count("im_v2.message_send_completions", on: sql) == 0)
                let retry = try V2MessageSendOperationCommand(command: .init(roomID: roomID,
                    senderUserID: senderID, clientMessageID: operation, text: "new valid input",
                    limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)
                let submitted = try await store.send(retry, token: token, capacityProfile: profile,
                    identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID())))
                guard case .receipt(let accepted) = submitted, case .accepted = accepted.outcome else {
                    throw V2MessageOperationValidationError.invalidReceipt
                }
                #expect(accepted.resolvedAtMilliseconds == UInt64(now.timeIntervalSince1970 * 1000))
                let replacement = v2FixtureMessageSendOperationStore(database: database,
                    writes: PostgresV2RoomWriteStore(database: database), clock: { now.addingTimeInterval(120) })
                #expect(try await replacement.recover(query(retry), token: token) == submitted)
                #expect(try await replacement.send(retry, token: token, capacityProfile: profile,
                    identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID()))) == submitted)
                let deadlineChanged = try V2MessageSendOperationCommand(command: retry.command,
                    firstSubmissionDeadlineMilliseconds: retry.firstSubmissionDeadlineMilliseconds + 1)
                #expect(try await replacement.recover(query(deadlineChanged), token: token) == .fingerprintConflict)
                #expect(try await replacement.recover(query(expired), token: token) == .fingerprintConflict)
                #expect(try await count("im_v2.messages", on: sql) == 1)
                #expect(try await count("im_v2.message_send_completions", on: sql) == 1)
            }
        }
    }
    @Test("Direct policy rejection stores no send result and permission changes allow the same identity to retry")
    func directPolicyRejectionLeavesNoRecoveryRecord() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(), profile = try forwardImportTestProfile()
            try await sql.raw("UPDATE im_v2.shard_admission_pools SET valid_until=clock_timestamp()+interval '10 minutes'").run()
            let recipient = UserID(uuid: memberTwoUUID)
            let room = try await V2DirectRoomOperationTestFixture(database: database,
                capacityProfile: profile, roomShardID: "room-a", now: { now }).openedIdentity(
                    actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: recipient,
                    firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
            try await withFixturePolicyOwners(database: database,
                projectionDelivery: SuccessfulProjectionDelivery()) { owners in
                let preferences = PostgresV2AccountPreferenceOperationStore(database: database,
                    projectionDelivery: SuccessfulProjectionDelivery(), policyOwners: owners)
                @Sendable func setPermission(_ allowed: Bool) async throws {
                    guard case .receipt(let receipt) = try await preferences.executePreferenceFixture(
                        owner: recipient, operation: .strangerMessagePreference(.init(uuid: UUID())),
                        value: .strangerMessage(allowed ? .allow : .deny), now: Date()),
                          case .applied = receipt.outcome else { throw CancellationError() }
                }
                try await setPermission(false)
                let policies = V2RoomPolicyAuthorizationService(roomDatabase: database,
                    policyOwners: owners, endpoint: "direct-rejection-test", maximumRooms: 1)
                do {
                    let writes = PostgresV2RoomWriteStore(database: database).usingPolicyAuthorizations(policies)
                    let store = PostgresV2MessageSendOperationStore(database: database, writes: writes)
                    try await withRoomActivation(database: database, roomID: room.roomID) { token in
                        let operation = ClientMessageID(uuid: UUID())
                        let denied = try V2MessageSendOperationCommand(command: .init(roomID: room.roomID,
                            senderUserID: senderID, clientMessageID: operation, text: "denied input",
                            limits: .init(maxUTF8Bytes: 64)),
                            firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
                        let result = try await store.send(denied, token: token, capacityProfile: profile,
                            identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID())))
                        guard case .receipt(let rejection) = result else { throw CancellationError() }
                        #expect(rejection.outcome == .rejected(.directPolicyDenied))
                        #expect(try await store.recover(.init(identity: denied.identity,
                            fingerprint: denied.fingerprint, domainFingerprint: denied.command.fingerprint), token: token) == .unresolved)
                        for table in ["messages", "message_send_completions"] {
                            #expect(try await count("im_v2." + table, on: sql) == 0)
                        }
                        try await setPermission(true)
                        let retry = try V2MessageSendOperationCommand(command: .init(roomID: room.roomID,
                            senderUserID: senderID, clientMessageID: operation, text: "allowed input",
                            limits: .init(maxUTF8Bytes: 64)),
                            firstSubmissionDeadlineMilliseconds: denied.firstSubmissionDeadlineMilliseconds)
                        let accepted = try await store.send(retry, token: token, capacityProfile: profile,
                            identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID())))
                        guard case .receipt(let success) = accepted, case .accepted = success.outcome else { throw CancellationError() }
                        #expect(try await store.recover(.init(identity: retry.identity, fingerprint: retry.fingerprint,
                            domainFingerprint: retry.command.fingerprint), token: token) == accepted)
                        #expect(try await count("im_v2.messages", on: sql) == 1)
                        #expect(try await count("im_v2.message_send_completions", on: sql) == 1)
                        #expect(try await retiredDirectDenialTableIsAbsent(on: sql))
                    }
                    await policies.shutdown()
                } catch {
                    await policies.shutdown()
                    throw error
                }
            }
        }
    }

}
