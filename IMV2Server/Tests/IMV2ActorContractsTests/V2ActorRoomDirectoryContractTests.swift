import Foundation
import IMV2ActorContracts
import IMV2Core
import Testing

@Suite("Room directory wire scope")
struct V2ActorRoomDirectoryContractTests {
    @Test("room queries expose room and authenticated actor; user enumeration remains separate")
    func scope() throws {
        let room = try RoomID("room-1")
        let user = try UserID("user-1")
        let membership = try V2ActorMembershipDirectoryQueryWire(roomID: room,
            actorUserID: user, cursor: "opaque", pageSize: 100)
        for query in [V2RoomDirectoryQuery.membership(membership),
                      .roleBaseline(.init(roomID: room, actorUserID: user))] {
            #expect(query.roomID == room)
            #expect(query.actorUserID == user)
            #expect(query.replayPolicy == .readOnly)
            #expect(try JSONDecoder().decode(V2RoomDirectoryQuery.self,
                from: JSONEncoder().encode(query)) == query)
        }
        #expect(throws: V2ActorRoomDirectoryWireError.invalidRequest) {
            try V2ActorMembershipDirectoryQueryWire(roomID: room,
                actorUserID: user, cursor: "   ", pageSize: 1)
        }
    }
}
