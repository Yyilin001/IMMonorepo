import Foundation
import IMV2Core
import Testing

@Suite("Author presentation receipts identify exact retained entries")
struct AuthorPresentationReceiptTests {
    @Test func bounds() throws {
        let user = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        for users in [[], [user, user], (0..<17).map { _ in UserID(uuid: UUID()) }] {
            #expect(throws: V2ResourceValidationError.invalidPresentationLease) {
                try V2AuthorPresentationReceipt(streamID: UUID(), viewID: UUID(), roomID: room, sequence: 1, userIDs: users)
            }
        }
        for sequence in [UInt64(0), UInt64.max] {
            #expect(throws: V2ResourceValidationError.invalidPresentationLease) {
                try V2AuthorPresentationReceipt(streamID: UUID(), viewID: UUID(), roomID: room, sequence: sequence, userIDs: [user])
            }
        }
        for remaining in [Int64(-1), 300_001, Int64.max] {
            #expect(throws: V2ResourceValidationError.invalidPresentationLease) {
                try V2AuthorPresentationReceipt(streamID: UUID(), viewID: UUID(), roomID: room, sequence: 1,
                    userIDs: [user], minimumRemainingMilliseconds: remaining)
            }
        }
        #expect(try V2AuthorPresentationReceipt(streamID: UUID(), viewID: UUID(), roomID: room, sequence: 1,
            userIDs: [user], minimumRemainingMilliseconds: 0).minimumRemainingMilliseconds == 0)
        let receipt = try V2AuthorPresentationReceipt(streamID: UUID(), viewID: UUID(), roomID: room,
                                                      sequence: 9, userIDs: [user])
        #expect(receipt.sequence == 9 && receipt.userIDs == [user])
    }
}
