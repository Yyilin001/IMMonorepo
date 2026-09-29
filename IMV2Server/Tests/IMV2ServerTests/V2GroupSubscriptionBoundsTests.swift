@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

struct V2GroupSubscriptionBoundsTests {
    @Test(arguments: ["watermark", "membership"], [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func returnedBounds(field: String, value: UInt64) async throws {
        let room = try RoomID("room"), user = try UserID("user")
        func construct() throws -> V2GroupEventSubscription {
        return try V2GroupEventSubscription(roomID: room,
            highWatermark: field == "watermark" ? value : 1,
            membershipRevision: field == "membership" ? value : 1)
        }
        if value > UInt64(Int64.max) {
            #expect(throws: V2GroupEventLogError.corruptPersistenceState) { try construct() }
            return
        }
        let expected = try construct()
        let service = V2GroupEventLogService(store: SubscriptionBoundsStore(value: expected))
        #expect(try await service.subscribe(roomID: room, actorUserID: user) == expected)
    }
}

private struct SubscriptionBoundsStore: V2GroupEventLogStore {
    let value: V2GroupEventSubscription
    func subscribe(roomID: RoomID, actorUserID: UserID) async throws -> V2GroupEventSubscription { value }
    func pull(roomID: RoomID, actorUserID: UserID, afterRoomSequence: UInt64, pageSize: Int) async throws -> V2GroupEventLogPage {
        throw V2GroupEventLogError.invalidRequest
    }
}
