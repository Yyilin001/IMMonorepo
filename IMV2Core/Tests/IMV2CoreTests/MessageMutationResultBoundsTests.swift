import IMV2Core
import Testing

struct MessageMutationResultBoundsTests {
    @Test(arguments: [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max],
          [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func editResult(revision: UInt64, sequence: UInt64) throws {
        func result() throws -> V2MessageEdit {
            try .init(roomID: .init("room"), messageID: .init("message"), text: "text", messageRevision: revision,
                roomSequence: sequence, eventID: .init("event"), createdAt: .distantPast)
        }
        if revision == 0 || sequence == 0 || revision > UInt64(Int64.max) || sequence > UInt64(Int64.max) {
            #expect(throws: V2RevisionValidationError.outOfRange) { _ = try result() }
        } else {
            let value = try result()
            #expect(value.messageRevision == revision)
            #expect(value.roomSequence == sequence)
        }
    }

    @Test(arguments: [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max],
          [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func withdrawalResult(revision: UInt64, sequence: UInt64) throws {
        func result() throws -> V2MessageWithdrawal {
            try .init(roomID: .init("room"), messageID: .init("message"), messageRevision: revision,
                roomSequence: sequence, eventID: .init("event"), createdAt: .distantPast)
        }
        if revision == 0 || sequence == 0 || revision > UInt64(Int64.max) || sequence > UInt64(Int64.max) {
            #expect(throws: V2RevisionValidationError.outOfRange) { _ = try result() }
        } else {
            let value = try result()
            #expect(value.messageRevision == revision)
            #expect(value.roomSequence == sequence)
        }
    }
}
