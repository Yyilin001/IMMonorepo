import IMV2Core
import Testing

@Suite("V2 message reactions")
struct MessageReactionTests {
    @Test("reaction input is normalized and set operations retain independent IDs")
    func normalizesReaction() throws {
        let command = try V2ChangeMessageReactionCommand(
            roomID: .init("room"), actorUserID: .init("user"), operationID: .init("operation"),
            messageID: .init("message"), reaction: "❤️", action: .add
        )
        #expect(command.action == .add)
        #expect(command.reaction == "❤️")
    }

    @Test("whitespace, controls, and oversized reaction values are rejected")
    func rejectsInvalidReaction() throws {
        #expect(throws: V2MessageReactionValidationError.invalidReaction) {
            try V2ChangeMessageReactionCommand(roomID: .init("room"), actorUserID: .init("user"), operationID: .init("operation"), messageID: .init("message"), reaction: " ", action: .add)
        }
        #expect(throws: V2MessageReactionValidationError.invalidReaction) {
            try V2ChangeMessageReactionCommand(roomID: .init("room"), actorUserID: .init("user"), operationID: .init("operation"), messageID: .init("message"), reaction: String(repeating: "a", count: 65), action: .remove)
        }
    }
}
