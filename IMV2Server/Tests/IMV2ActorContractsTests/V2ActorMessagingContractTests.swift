import Foundation
import IMV2ActorContracts
import IMV2Core
import Testing

@Suite("D1 messaging wire contract")
struct V2ActorMessagingContractTests {
    @Test("typed operation commands preserve scope, frozen deadline and replay identity")
    func commands() throws {
        let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID()), message = MessageID(uuid: UUID())
        let send = try V2MessageSendOperationCommand(command: .init(roomID: room, senderUserID: user,
            clientMessageID: .init(uuid: UUID()), text: "hello", limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)
        let commands: [V2RoomMessagingCommand] = [
            .sendOperation(send),
            .editOperation(try .init(command: .init(roomID: room, actorUserID: user, operationID: .init(uuid: UUID()),
                messageID: message, expectedMessageRevision: 2, text: "edited", maximumUTF8Bytes: 64), firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)),
            .withdrawOperation(try .init(command: .init(roomID: room, actorUserID: user, operationID: .init(uuid: UUID()),
                messageID: message, expectedMessageRevision: 3), firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)),
            .reactionOperation(try .init(command: .init(roomID: room, actorUserID: user, operationID: .init(uuid: UUID()),
                messageID: message, reaction: "👍", action: .add), expectedReactionRevision: 0, firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)),
        ]
        for command in commands {
            #expect(command.roomID == room && command.actorUserID == user)
            #expect(command.retryPolicy == .durableIdempotent)
            let decoded = try JSONDecoder().decode(V2RoomMessagingCommand.self, from: JSONEncoder().encode(command))
            #expect(decoded == command && decoded.operationID == command.operationID)
        }
        #expect(commands[0].operationID == .send(send.command.clientMessageID))
    }

    @Test("current result families preserve unresolved and fingerprint conflict distinctly")
    func results() throws {
        let results: [V2RoomMessagingResult] = [
            .sendOperation(.unresolved), .sendOperation(.fingerprintConflict),
            .mutation(.unresolved), .mutation(.fingerprintConflict),
            .reactionOperation(.unresolved), .reactionOperation(.fingerprintConflict),
        ]
        for result in results {
            #expect(try JSONDecoder().decode(V2RoomMessagingResult.self, from: JSONEncoder().encode(result)) == result)
        }
    }
}
