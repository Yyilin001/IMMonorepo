import Foundation
import IMV2ActorContracts
import IMV2Core
import Testing

@Suite("D1 messaging wire contract")
struct V2ActorMessagingContractTests {
    @Test("all command discriminators preserve scoped operation identities and fixed replay policy")
    func commands() throws {
        let room = try RoomID("room-1")
        let user = try UserID("user-1")
        let message = try MessageID("message-1")
        let send = V2ActorSendMessageWire(roomID: room, actorUserID: user,
            clientMessageID: try ClientMessageID("client-1"), text: "hello", media: [],
            mentions: [.everyone, .user(user)], entities: [], replyTo: nil)
        let commands: [V2RoomMessagingCommand] = [
            .send(send),
            .edit(.init(roomID: room, actorUserID: user,
                        operationID: try MessageEditOperationID("edit-1"), messageID: message,
                        expectedMessageRevision: 2, text: "edited")),
            .withdraw(.init(roomID: room, actorUserID: user,
                            operationID: try MessageWithdrawalOperationID("withdraw-1"),
                            messageID: message, expectedMessageRevision: 3)),
            .reaction(.init(roomID: room, actorUserID: user,
                            operationID: try MessageReactionOperationID("reaction-1"),
                            messageID: message, reaction: "👍", action: .add)),
        ]
        for command in commands {
            #expect(command.roomID == room)
            #expect(command.actorUserID == user)
            #expect(command.retryPolicy == .durableIdempotent)
            #expect(try JSONDecoder().decode(V2RoomMessagingCommand.self,
                from: JSONEncoder().encode(command)) == command)
        }
        #expect(commands.map(\.operationID) == [
            .send(send.clientMessageID), .edit(try MessageEditOperationID("edit-1")),
            .withdraw(try MessageWithdrawalOperationID("withdraw-1")),
            .reaction(try MessageReactionOperationID("reaction-1")),
        ])
    }

    @Test("all result variants retain their distinct case and payload")
    func results() throws {
        let room = try RoomID("room-1")
        let message = try MessageID("message-1")
        let event = try EventID("event-1")
        let user = try UserID("user-1")
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        let edit = V2ActorMessageEditWire(roomID: room, messageID: message, text: "new",
            messageRevision: 2, roomSequence: 3, eventID: event, createdAt: time)
        let withdrawal = V2ActorMessageWithdrawalWire(roomID: room, messageID: message,
            messageRevision: 3, roomSequence: 4, eventID: event, createdAt: time)
        let reaction = V2ActorMessageReactionChangeWire(roomID: room, messageID: message,
            actorUserID: user, reaction: "👍", action: .add, roomSequence: 5,
            eventID: event, createdAt: time)
        let receipt = V2ActorMessageAcceptanceReceiptWire(messageID: message, roomID: room,
            roomSequence: 1, timelineSequence: 7, senderUserID: user,
            clientMessageID: try ClientMessageID("client-1"), groupCapacityClass: nil,
            sourceEventID: event, acceptedMembershipRevision: 8,
            directRecipientUserID: user, createdAt: time)
        let denied = V2ActorDirectMessageDeniedWire(roomID: room, sourceEventID: event,
            timelineSequence: 9, createdAt: time, reason: .systemAccountReadOnly)
        let results: [V2RoomMessagingResult] = [
            .send(.idempotent(receipt)), .send(.denied(denied)),
            .send(.idempotencyConflict), .send(.rateLimited(retryAfterSeconds: 4)),
            .send(.unavailable(.missingShardLease)),
            .edit(.edited(edit)), .edit(.idempotent(edit)),
            .edit(.revisionConflict(current: 2)), .edit(.alreadyWithdrawn),
            .withdraw(.withdrawn(withdrawal)), .withdraw(.idempotent(withdrawal)),
            .withdraw(.revisionConflict(current: 3)),
            .reaction(.changed(reaction)), .reaction(.idempotent(reaction)),
            .reaction(.alreadyInDesiredState),
        ]
        for result in results {
            #expect(try JSONDecoder().decode(V2RoomMessagingResult.self,
                from: JSONEncoder().encode(result)) == result)
        }
    }
}
