import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

struct V2MutationResponseBoundsTests {
    @Test(arguments: ["editRevision", "editSequence", "withdrawalRevision", "withdrawalSequence", "receiptSequence", "reactionSequence"],
          [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func responseIntegers(scenario: String, value: UInt64) throws {
        let room = RoomID(uuid: UUID()), message = MessageID(uuid: UUID()), actor = UserID(uuid: UUID())
        func returnedValue() throws -> UInt64 {
            if scenario == "receiptSequence" {
                return try V2ReadReceipt(roomID: room, userID: actor, readThroughRoomSequence: value, recordedAt: Date()).readThroughRoomSequence
            }
            if scenario == "reactionSequence" { return try V2MessageReactionEventProof(roomSequence: value, eventID: .init(uuid: UUID())).roomSequence }
            let revision = scenario.hasSuffix("Revision") ? value : 2
            let sequence = scenario.hasSuffix("Sequence") ? value : 2
            let result = try V2MessageMutationCommit(messageID: message, messageRevision: revision, roomSequence: sequence, eventID: .init(uuid: UUID()))
            return scenario.hasSuffix("Revision") ? result.messageRevision : result.roomSequence
        }
        if value == 0 || value > UInt64(Int64.max) {
            #expect(throws: (any Error).self) { _ = try returnedValue() }
        } else { #expect(try returnedValue() == value) }
    }
    @Test(arguments: ["editRevision", "withdrawalRevision"], [UInt64(1), UInt64(Int64.max) - 2, UInt64(Int64.max) - 1])
    func committedRevision(scenario: String, expected: UInt64) throws {
        let room = RoomID(uuid: UUID()), message = MessageID(uuid: UUID()), actor = UserID(uuid: UUID())
        let payload: V2MessageMutationPayload
        if scenario == "editRevision" {
            payload = .edit(try .init(command: .init(roomID: room, actorUserID: actor, operationID: .init(uuid: UUID()), messageID: message,
                expectedMessageRevision: expected, text: "text", maximumUTF8Bytes: 1024), firstSubmissionDeadlineMilliseconds: 1000))
        } else {
            payload = .withdraw(try .init(command: .init(roomID: room, actorUserID: actor, operationID: .init(uuid: UUID()), messageID: message,
                expectedMessageRevision: expected), firstSubmissionDeadlineMilliseconds: 1000))
        }
        for returned in [expected - 1, expected, expected + 1, expected + 2] {
            if returned == 0 || returned > UInt64(Int64.max) {
                #expect(throws: (any Error).self) { try V2MessageMutationCommit(messageID: message, messageRevision: returned, roomSequence: 1, eventID: .init(uuid: UUID())) }
                continue
            }
            let result = try V2MessageMutationCommit(messageID: message, messageRevision: returned, roomSequence: 1, eventID: .init(uuid: UUID()))
            let receipt = try V2MessageMutationReceipt(identity: payload.identity, fingerprint: payload.fingerprint, outcome: .committed(result), resolvedAtMilliseconds: 100)
            #expect(try payload.validates(receipt) == (returned == expected + 1))
        }
    }
}
