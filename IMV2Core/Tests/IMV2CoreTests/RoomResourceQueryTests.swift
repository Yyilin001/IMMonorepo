import Foundation
import IMV2Core
import Testing

struct RoomResourceQueryTests {
    @Test func requestAndPositionRejectInvalidWireValues() throws {
        #expect(throws: V2ResourceValidationError.invalidDescriptor) { try V2RoomResourceQuery(limit: 101) }
        #expect(throws: V2ResourceValidationError.invalidDescriptor) { try V2RoomResourceQuery(before: 100, after: 100) }
        #expect(throws: V2ResourceValidationError.invalidDescriptor) { try V2RoomResourceQuery(cursor: String(repeating: "x", count: 4097)) }
        #expect(throws: V2ResourceValidationError.invalidDescriptor) {
            try JSONDecoder().decode(V2RoomResourceQuery.self, from: Data("{\"category\":\"all\",\"limit\":0}".utf8))
        }
        #expect(throws: V2ResourceValidationError.invalidDescriptor) {
            try V2RoomResourcePosition(roomSequence: UInt64(Int64.max) + 1, ordinal: 0, mediaID: .init(uuid: UUID()))
        }
    }

    @Test func pagesRejectDuplicateOrUnorderedPositionsAndBadUpperBound() throws {
        let room = RoomID(uuid: UUID()), media = MediaID(uuid: UUID())
        let descriptor = try V2ResourceDescriptor(key: .init(home: .room(room), mediaID: media), revision: 1, displayName: .attachment,
            contentType: "image/jpeg", byteCount: 32, checksum: .init(value: String(repeating: "a", count: 64)), state: .ready)
        let first = try V2RoomResourceItem(messageID: .init(uuid: UUID()), messageRevision: 1,
            position: .init(roomSequence: 10, ordinal: 0, mediaID: media), createdAt: 1000, descriptor: descriptor)
        let second = try V2RoomResourceItem(messageID: .init(uuid: UUID()), messageRevision: 1,
            position: .init(roomSequence: 9, ordinal: 0, mediaID: media), createdAt: 999, descriptor: descriptor)
        #expect(throws: V2ResourceValidationError.invalidDescriptor) { try V2RoomResourcePage(items: [first,first], snapshotUpperRoomSequence: 10, nextCursor: nil) }
        #expect(throws: V2ResourceValidationError.invalidDescriptor) { try V2RoomResourcePage(items: [second,first], snapshotUpperRoomSequence: 10, nextCursor: nil) }
        #expect(throws: V2ResourceValidationError.invalidDescriptor) { try V2RoomResourcePage(items: [first], snapshotUpperRoomSequence: 9, nextCursor: nil) }
        let page = try V2RoomResourcePage(items: [first,second], snapshotUpperRoomSequence: 10, nextCursor: nil)
        #expect(try JSONDecoder().decode(V2RoomResourcePage.self, from: JSONEncoder().encode(page)) == page)
    }
}
