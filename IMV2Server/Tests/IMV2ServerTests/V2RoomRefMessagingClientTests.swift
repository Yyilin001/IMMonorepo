@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("Logical messaging client")
struct V2RoomRefMessagingClientTests {
    @Test("typed send preserves frozen identity within a single total budget")
    func sendIdentity() async throws {
        let user = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        let command = try V2MessageSendOperationCommand(command: .init(roomID: room, senderUserID: user,
            clientMessageID: .init(uuid: UUID()), text: "test", limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)
        let started = ContinuousClock.now
        let client = V2RoomRefMessagingClient(callTimeout: try .init(2_000)) { request, assertedUser, deadline in
            #expect(assertedUser == user)
            #expect(deadline >= started && deadline <= .now + .seconds(2))
            guard case .messaging(.sendOperation(let frozen)) = request else { throw V2RoomCallFailure.outcomeUnknown }
            #expect(frozen == command)
            return .messaging(.sendOperation(.fingerprintConflict))
        }
        #expect(try await client.sendOperation(command) == .fingerprintConflict)
        #expect(client.managesForegroundWriteAdmission)
    }

    @Test("send recovery can return committed results while the room actor is unavailable")
    func recoveryBypassesActor() async throws {
        let command = try V2MessageSendOperationCommand(command: .init(roomID: .init(uuid: UUID()),
            senderUserID: .init(uuid: UUID()), clientMessageID: .init(uuid: UUID()),
            text: "lost response", limits: .init(maxUTF8Bytes: 64)),
            firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)
        let request = try V2MessageSendOperationRecoveryRequest(identity: command.identity,
            fingerprint: command.fingerprint, domainFingerprint: command.command.fingerprint, action: .query)
        let receipt = try V2MessageSendOperationReceipt(identity: request.identity,
            fingerprint: request.fingerprint,
            outcome: .accepted(.init(messageID: .init(uuid: UUID()), roomSequence: 1)),
            resolvedAtMilliseconds: 1_750_000_000_000)
        let client = V2RoomRefMessagingClient(callTimeout: try .init(1_000), recoveryQuery: { actual in
            #expect(actual == request)
            return .receipt(receipt)
        }) { _, _, _ in
            Issue.record("A result query must not activate or call the room")
            throw V2RoomCallFailure.notAccepted(.unavailable)
        }
        #expect(client.usesReadOnlySendRecovery)
        #expect(try await client.recoverSendOperation(request) == .receipt(receipt))
    }

    @Test("typed rejections survive the boundary and unexpected responses remain unknown")
    func failures() async throws {
        let command = try V2MessageWithdrawalOperationCommand(command: .init(roomID: .init(uuid: UUID()),
            actorUserID: .init(uuid: UUID()), operationID: .init(uuid: UUID()), messageID: .init(uuid: UUID()),
            expectedMessageRevision: 1), firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)
        let rejected = V2RoomRefMessagingClient(callTimeout: try .init(1_000)) { _, _, _ in
            .messaging(.failure(.withdrawalStore(.actorNotAuthor)))
        }
        await #expect(throws: V2MessageWithdrawalStoreError.actorNotAuthor) { _ = try await rejected.withdrawOperation(command) }
        let cancelled = V2RoomRefMessagingClient(callTimeout: try .init(1_000)) { _, _, _ in
            throw V2RoomCallFailure.notAccepted(.cancelled)
        }
        await #expect(throws: CancellationError.self) { _ = try await cancelled.withdrawOperation(command) }
        let unknown = V2RoomRefMessagingClient(callTimeout: try .init(1_000)) { _, _, _ in
            throw V2RoomCallFailure.outcomeUnknown
        }
        await #expect(throws: V2RoomCallFailure.outcomeUnknown) { _ = try await unknown.withdrawOperation(command) }
        let wrong = V2RoomRefMessagingClient(callTimeout: try .init(1_000)) { _, _, _ in
            .messaging(.sendOperation(.fingerprintConflict))
        }
        await #expect(throws: V2RoomCallFailure.outcomeUnknown) { _ = try await wrong.withdrawOperation(command) }
    }
}
