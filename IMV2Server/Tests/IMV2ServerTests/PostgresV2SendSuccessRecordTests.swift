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
            let store = PostgresV2MessageSendOperationStore(database: database,
                writes: PostgresV2RoomWriteStore(database: database), clock: { now })
            let expired = try V2MessageSendOperationCommand(command: .init(roomID: roomID,
                senderUserID: senderID, clientMessageID: operation, text: "expired input",
                limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: 1_749_999_999_000)
            func query(_ command: V2MessageSendOperationCommand) throws -> V2MessageSendOperationRecoveryRequest {
                try .init(identity: command.identity, fingerprint: command.fingerprint,
                    domainFingerprint: command.command.fingerprint, action: .query)
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
                let replacement = PostgresV2MessageSendOperationStore(database: database,
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
}
