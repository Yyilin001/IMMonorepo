import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("Logical messaging client")
struct V2RoomRefMessagingClientTests {
    @Test("send preserves authenticated user and client identity within a single total budget")
    func sendIdentity() async throws {
        let user = UserID(uuid: UUID()), room = RoomID(uuid: UUID()), clientID = ClientMessageID(uuid: UUID())
        let started = ContinuousClock.now
        let client = V2RoomRefMessagingClient(callTimeout: try .init(2_000)) { request, assertedUser, deadline in
            #expect(assertedUser == user)
            #expect(deadline >= started && deadline <= .now + .seconds(2))
            guard case .messaging(.send(let wire)) = request else {
                Issue.record("wrong capability"); throw V2RoomCallFailure.outcomeUnknown
            }
            #expect(wire.actorUserID == user && wire.roomID == room && wire.clientMessageID == clientID)
            #expect(wire.text == "test")
            return .messaging(.send(.idempotencyConflict))
        }
        #expect(try await client.send(.init(roomID: room, actorUserID: user,
            clientMessageID: clientID, text: "test")) == .idempotencyConflict)
        #expect(client.managesForegroundWriteAdmission)
    }

    @Test("typed rejections survive the boundary and unexpected responses remain unknown")
    func failures() async throws {
        let request = V2AuthenticatedMessageWithdrawal(roomID: .init(uuid: UUID()),
            actorUserID: .init(uuid: UUID()), operationID: .init(uuid: UUID()),
            messageID: .init(uuid: UUID()), expectedMessageRevision: 1)
        let rejected = V2RoomRefMessagingClient(callTimeout: try .init(1_000)) { _, _, _ in
            .messaging(.failure(.withdrawalStore(.actorNotAuthor)))
        }
        await #expect(throws: V2MessageWithdrawalStoreError.actorNotAuthor) {
            _ = try await rejected.withdraw(request)
        }
        let wrong = V2RoomRefMessagingClient(callTimeout: try .init(1_000)) { _, _, _ in
            .messaging(.send(.idempotencyConflict))
        }
        await #expect(throws: V2RoomCallFailure.outcomeUnknown) {
            _ = try await wrong.withdraw(request)
        }
    }
}
