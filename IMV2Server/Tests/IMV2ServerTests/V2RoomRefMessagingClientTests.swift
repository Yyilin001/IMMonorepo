import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
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
