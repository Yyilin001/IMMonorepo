import IMV2Core
import Testing

struct ReactionReceiptResultBoundsTests {
    @Test(arguments: ["reaction", "receipt"], [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func persistenceBounds(kind: String, sequence: UInt64) throws {
        func resultSequence() throws -> UInt64 {
            if kind == "reaction" {
                return try V2MessageReactionChange(roomID: .init("room"), messageID: .init("message"), actorUserID: .init("user"),
                    reaction: "👍", action: .add, roomSequence: sequence, eventID: .init("event"), fanoutPlanID: .init("plan"), createdAt: .distantPast).roomSequence
            }
            return try V2ReadReceipt(roomID: .init("room"), userID: .init("user"), readThroughRoomSequence: sequence, recordedAt: .distantPast).readThroughRoomSequence
        }
        if sequence == 0 || sequence > UInt64(Int64.max) {
            #expect(throws: V2RevisionValidationError.outOfRange) { _ = try resultSequence() }
        } else {
            #expect(try resultSequence() == sequence)
        }
    }
}
