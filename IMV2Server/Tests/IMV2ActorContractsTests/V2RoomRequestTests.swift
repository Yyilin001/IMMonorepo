import Foundation
import IMV2Core
import Testing
@testable import IMV2ActorContracts

@Suite("Closed room capability envelope")
struct V2RoomRequestTests {
    @Test("retry and batching policy come from the typed capability")
    func policyAndIdentity() throws {
        let room = RoomID(uuid: UUID())
        let user = UserID(uuid: UUID())
        let message = ClientMessageID(uuid: UUID())
        let send = V2RoomRequest.messaging(.send(.init(
            roomID: room, actorUserID: user, clientMessageID: message, text: "message",
            media: [], mentions: [], entities: [], replyTo: nil
        )))
        let encoded = try JSONEncoder().encode(send)
        let decoded = try JSONDecoder().decode(V2RoomRequest.self, from: encoded)
        #expect(decoded == send)
        #expect(decoded.roomID == room)
        #expect(decoded.actorUserID == user)
        #expect(decoded.replayPolicy == .durableIdempotent)
        #expect(decoded.hasStableOperationID)
        #expect(decoded.canShareSendTurn)

        let query = V2RoomRequest.recovery(.init(roomID: room, actorUserID: user, kind: .state))
        #expect(query.roomID == room)
        #expect(query.replayPolicy == .readOnly)
        #expect(!query.hasStableOperationID)
        #expect(!query.canShareSendTurn)
        #expect(try JSONDecoder().decode(V2RoomRequest.self, from: JSONEncoder().encode(query)) == query)
    }

    @Test("trusted safety is distinct from user-authored moderation")
    func trustedPrincipalBoundary() throws {
        let room = RoomID(uuid: UUID())
        let operation = ModerationOperationID(uuid: UUID())
        let request = V2RoomRequest.administration(.trustedSafety(.init(
            roomID: room, operationID: operation, action: .redactMessage,
            messageID: MessageID(uuid: UUID()), expectedMessageRevision: 7, reasonCode: "review"
        )))
        #expect(request.actorUserID == nil)
        #expect(request.roomID == room)
        #expect(request.hasStableOperationID)
        #expect(!request.canShareSendTurn)
    }

    @Test("unknown capabilities and collection queries cannot masquerade as one room turn")
    func unknownDiscriminator() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(V2RoomRequest.self, from: Data(#"{"futureCapability":{}}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(V2RoomRequest.self, from: Data(#"{"recovery":{"roomIDs":[],"actorUserID":{"rawValue":"user"}}}"#.utf8))
        }
    }

    @Test("unavailable and retry survive a per-room recovery reply")
    func resultDistinctions() throws {
        let values: [V2RoomResponse] = [
            .recovery(.state(.unavailable)), .recovery(.state(.retry)),
            .recovery(.latestVisible(.unavailable)), .recovery(.latestVisible(.retry)),
        ]
        for value in values {
            #expect(try JSONDecoder().decode(V2RoomResponse.self, from: JSONEncoder().encode(value)) == value)
        }
    }
}
