import Foundation
import IMV2Core
import Testing

struct DirectReceiptProjectionBoundsTests {
    @Test(arguments: [false, true], [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func persistenceBounds(visible: Bool, sequence: UInt64) throws {
        func projection() throws -> V2DirectReadReceiptProjection {
            try .init(roomID: .init("room"), readerUserID: .init("reader"),
                      readThroughRoomSequence: sequence, recordedAt: .distantPast, isVisible: visible)
        }
        if sequence > UInt64(Int64.max) {
            #expect(throws: V2RevisionValidationError.outOfRange) { _ = try projection() }
        } else {
            let value = try projection()
            #expect(value.readThroughRoomSequence == sequence)
            #expect(value.isVisible == visible)
        }
    }
}
