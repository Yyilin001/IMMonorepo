import Foundation
@testable import IMV2Core
import Testing

struct GroupRoomCountBoundsTests {
    @Test(arguments: [Int.min, -1, 0, 1, Int(UInt32.max), Int(UInt32.max) + 1, Int.max])
    func countBounds(count: Int) throws {
        let owner = UserID(uuid: UUID())
        func room() throws -> V2GroupRoom {
            try V2GroupRoom(roomID: .init(uuid: UUID()), ownerUserID: owner, title: "group", capacityClass: .large,
                memberUserIDs: [owner], memberCount: count, createdAt: Date(timeIntervalSince1970: 1_000))
        }
        if count <= 0 || count > Int(UInt32.max) {
            #expect(throws: V2GroupMessagingValidationError.invalidMemberCount) { try room() }
        } else {
            #expect(try room().memberCount == count)
        }
    }
    @Test func countMustCoverMaterializedMembers() throws {
        let owner = UserID(uuid: UUID()), member = UserID(uuid: UUID())
        #expect(throws: V2GroupMessagingValidationError.invalidMemberCount) {
            try V2GroupRoom(roomID: .init(uuid: UUID()), ownerUserID: owner, title: "group", capacityClass: .standard,
                memberUserIDs: [owner, member], memberCount: 1, createdAt: .distantPast)
        }
        let room = try V2GroupRoom(roomID: .init(uuid: UUID()), ownerUserID: owner, title: "group", capacityClass: .standard,
            memberUserIDs: [owner, member], createdAt: .distantPast)
        #expect(room.memberCount == 2)
    }
}
