@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

struct V2GroupResponseConstructionTests {
    @Test(arguments: ["event", "page", "subscription", "membership"], [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func bounds(field: String, value: UInt64) throws {
        let room = RoomID(uuid: UUID())
        func construct() throws -> UInt64 {
            switch field {
            case "event": return try V2GroupEventLogEntry(sourceEventID: .init(uuid: UUID()), roomSequence: value, projectionKind: "message", payload: Data()).roomSequence
            case "page": return try V2GroupEventLogPage(roomID: room, events: [], nextRoomSequence: value, hasMore: false).nextRoomSequence
            case "subscription": return try V2GroupEventSubscription(roomID: room, highWatermark: value).highWatermark
            default: return try V2GroupEventSubscription(roomID: room, highWatermark: 0, membershipRevision: value).membershipRevision
            }
        }
        if value > UInt64(Int64.max) || (field == "event" && value == 0) {
            #expect(throws: V2GroupEventLogError.corruptPersistenceState) { try construct() }
        } else {
            #expect(try construct() == value)
        }
    }
}
