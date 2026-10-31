import Foundation
import IMV2Core
import Testing

struct AuthorPresentationContextTests {
    @Test func independentStartDoesNotRequireARoom() throws {
        let stream = UUID(), view = UUID(), room = RoomID(uuid: UUID())
        #expect(try V2AuthorPresentationStart(streamID: stream, viewID: view, messageRoomIDs: []).messageRoomIDs.isEmpty)
        #expect(try V2AuthorPresentationStart(streamID: stream, viewID: view, messageRoomIDs: [room]).messageRoomIDs == [room])
        for rooms in [[room, room], (0..<9).map { _ in RoomID(uuid: UUID()) }, [try RoomID("not-a-uuid")]] {
            #expect(throws: V2ResourceValidationError.self) {
                try V2AuthorPresentationStart(streamID: stream, viewID: view, messageRoomIDs: rooms)
            }
        }
    }

    @Test func fullKeysAreDistinctForInterestAndReceipt() throws {
        let stream = UUID(), view = UUID(), user = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        let keys: [V2ProfileViewLookupKey] = [.init(userID: user, context: .room(room)),
            .init(userID: user, context: .groupJoinReview(room)), .init(userID: user, context: .relationship),
            .init(userID: user, context: .directConversation)]
        #expect(try V2AuthorPresentationInterests(streamID: stream, viewID: view, sequence: 1, keys: keys).keys == keys)
        #expect(try V2AuthorPresentationReceipt(streamID: stream, viewID: view, sequence: 1, keys: keys,
            minimumRemainingMilliseconds: 0).keys == keys)
        for invalid in [keys + [keys[0]], [.init(userID: user, context: .room(try RoomID("not-a-uuid")))]] {
            #expect(throws: V2ResourceValidationError.self) {
                try V2AuthorPresentationInterests(streamID: stream, viewID: view, sequence: 1, keys: invalid)
            }
            #expect(throws: V2ResourceValidationError.self) {
                try V2AuthorPresentationReceipt(streamID: stream, viewID: view, sequence: 1, keys: invalid, minimumRemainingMilliseconds: 0)
            }
        }
    }
}
