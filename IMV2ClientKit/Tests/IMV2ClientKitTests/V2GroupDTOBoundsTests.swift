import Foundation
import IMV2Core
import IMV2ClientKit
import Testing

struct V2GroupDTOBoundsTests {
    @Test(arguments: [Int.min, -1, 0, 1, Int.max])
    func commitCount(value: Int) throws {
        if value < 0 {
            #expect(throws: V2ClientSyncError.invalidRecordOrdering) {
                try V2GroupEventPageCommit(appliedThrough: 0, insertedEventCount: value)
            }
        } else {
            #expect(try V2GroupEventPageCommit(appliedThrough: 0, insertedEventCount: value).insertedEventCount == value)
        }
    }

    @Test(arguments: ["event", "page", "subscription", "members", "commit"], [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func construction(field: String, value: UInt64) throws {
        let room = RoomID(uuid: UUID())
        func construct() throws -> UInt64 {
            switch field {
            case "event": return try V2ClientGroupEvent(sourceEventID: .init(uuid: UUID()), roomSequence: value, projectionKind: "message", payload: Data("{}".utf8)).roomSequence
            case "page": return try V2ClientGroupEventPage(roomID: room, events: [], nextRoomSequence: value, hasMore: false).nextRoomSequence
            case "members": return try V2ClientRoomMembersPage(roomID: room, membershipRevision: value, actorRole: .member, members: [], nextCursor: nil).membershipRevision
            case "commit": return try V2GroupEventPageCommit(appliedThrough: value, insertedEventCount: 0).appliedThrough
            default: return try V2ClientGroupEventSubscription(roomID: room, highWatermark: value).highWatermark
            }
        }
        if value > UInt64(Int64.max) {
            #expect(throws: V2ClientSyncError.storageRangeExceeded) { try construct() }
        } else if value == 0 && field == "event" {
            #expect(throws: V2ClientSyncError.invalidRecordOrdering) { try construct() }
        } else { #expect(try construct() == value) }
    }
}
