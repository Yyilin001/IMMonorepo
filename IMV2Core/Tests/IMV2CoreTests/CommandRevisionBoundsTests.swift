import IMV2Core
import Testing

@Suite("Command revision persistence bounds")
struct CommandRevisionBoundsTests {
    @Test(arguments: [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func readReceiptSequenceMatchesSignedPersistence(_ sequence: UInt64) throws {
        func command() throws -> V2RecordReadReceiptCommand {
            try .init(roomID: .init("room"), actorUserID: .init("actor"), operationID: .init("receipt"), readThroughRoomSequence: sequence)
        }
        if sequence == 0 || sequence > UInt64(Int64.max) {
            #expect(throws: V2ReadReceiptValidationError.invalidRoomSequence) { try command() }
        } else {
            #expect(try command().readThroughRoomSequence == sequence)
        }
    }

    @Test(arguments: [UInt64(0), UInt64(Int64.max) + 1, UInt64.max])
    func rejectsInvalidContentRevisionBeforeAnyStoreLookup(_ revision: UInt64) throws {
        let room = try RoomID("room")
        let actor = try UserID("actor")
        let message = try MessageID("message")
        #expect(throws: V2RevisionValidationError.outOfRange) {
            _ = try V2EditMessageCommand(
                roomID: room, actorUserID: actor, operationID: .init("edit"),
                messageID: message, expectedMessageRevision: revision,
                text: "replacement", maximumUTF8Bytes: 100
            )
        }
        #expect(throws: V2RevisionValidationError.outOfRange) {
            _ = try V2WithdrawMessageCommand(
                roomID: room, actorUserID: actor, operationID: .init("withdraw"),
                messageID: message, expectedMessageRevision: revision
            )
        }
    }

    @Test(arguments: [UInt64(Int64.max) + 1, UInt64.max])
    func rejectsOverflowingMembershipFence(_ revision: UInt64) throws {
        #expect(throws: V2RevisionValidationError.outOfRange) {
            _ = try V2ChangeRoomMembershipCommand(
                roomID: .init("room"), actorUserID: .init("actor"),
                operationID: .init("membership"), targetUserID: .init("target"),
                action: .add, expectedMembershipRevision: revision
            )
        }
    }

    @Test(arguments: [UInt64(1), UInt64(Int64.max)])
    func preservesExactContentFence(_ revision: UInt64) throws {
        let edit = try V2EditMessageCommand(
            roomID: .init("room"), actorUserID: .init("actor"), operationID: .init("edit"),
            messageID: .init("message"), expectedMessageRevision: revision,
            text: "replacement", maximumUTF8Bytes: 100
        )
        let withdraw = try V2WithdrawMessageCommand(
            roomID: edit.roomID, actorUserID: edit.actorUserID, operationID: .init("withdraw"),
            messageID: edit.messageID, expectedMessageRevision: revision
        )
        #expect(edit.expectedRevision.signedValue == Int64(exactly: revision))
        #expect(withdraw.expectedRevision == edit.expectedRevision)
        #expect(withdraw.expectedMessageRevision == revision)
    }

    @Test(arguments: [UInt64(0), UInt64(1), UInt64(Int64.max)])
    func preservesInitialAndMaximumMembershipFences(_ revision: UInt64) throws {
        let command = try V2ChangeRoomMembershipCommand(
            roomID: .init("room"), actorUserID: .init("actor"),
            operationID: .init("membership"), targetUserID: .init("target"),
            action: .add, expectedMembershipRevision: revision
        )
        #expect(command.expectedRevision.signedValue == Int64(exactly: revision))
        #expect(command.expectedMembershipRevision == revision)
    }
}
