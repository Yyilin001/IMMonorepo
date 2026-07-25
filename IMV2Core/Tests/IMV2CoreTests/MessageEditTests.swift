import Foundation
import IMV2Core
import Testing

@Suite("V2 message edit command")
struct MessageEditTests {
    @Test("edits keep durable identity and reject empty or oversized replacements")
    func validatesReplacementTextAndRetainsRevisionFence() throws {
        let command = try V2EditMessageCommand(
            roomID: .init("room-1"),
            actorUserID: .init("user-1"),
            operationID: .init("operation-1"),
            messageID: .init("message-1"),
            expectedMessageRevision: 7,
            text: "replacement",
            maximumUTF8Bytes: 16
        )
        #expect(command.operationID.rawValue == "operation-1")
        #expect(command.expectedMessageRevision == 7)
        #expect(command.text == "replacement")
        #expect(throws: V2MessageEditValidationError.invalidText) {
            _ = try V2EditMessageCommand(roomID: command.roomID, actorUserID: command.actorUserID, operationID: command.operationID, messageID: command.messageID, expectedMessageRevision: 7, text: "", maximumUTF8Bytes: 16)
        }
        #expect(throws: V2MessageEditValidationError.invalidText) {
            _ = try V2EditMessageCommand(roomID: command.roomID, actorUserID: command.actorUserID, operationID: command.operationID, messageID: command.messageID, expectedMessageRevision: 7, text: "0123456789abcdef", maximumUTF8Bytes: 15)
        }
    }
}
