import Foundation
import IMV2ActorContracts
import IMV2Core
import Testing

@Suite("Room recovery wire bounds")
struct V2ActorRoomRecoveryContractTests {
    @Test("one typed request retains 100 room identities and read-only classification")
    func boundedBatch() throws {
        let rooms = try (0..<100).map { try RoomID("room-\($0)") }
        let user = try UserID("user-1")
        let request = try V2ActorRoomRecoveryBatchQueryWire(roomIDs: rooms, actorUserID: user)
        for query in [V2RoomRecoveryQuery.states(request), .latestVisible(request)] {
            #expect(query.roomIDs == rooms)
            #expect(query.actorUserID == user)
            #expect(query.replayPolicy == .readOnly)
            #expect(try JSONDecoder().decode(V2RoomRecoveryQuery.self,
                from: JSONEncoder().encode(query)) == query)
        }
        #expect(throws: V2ActorRoomRecoveryWireError.invalidBatch) {
            try V2ActorRoomRecoveryBatchQueryWire(roomIDs: [], actorUserID: user)
        }
        #expect(throws: V2ActorRoomRecoveryWireError.invalidBatch) {
            try V2ActorRoomRecoveryBatchQueryWire(roomIDs: rooms + [rooms[0]], actorUserID: user)
        }
        #expect(throws: V2ActorRoomRecoveryWireError.invalidBatch) {
            try V2ActorRoomRecoveryBatchQueryWire(roomIDs: [rooms[0], rooms[0]], actorUserID: user)
        }
    }

    @Test("state and latest partial results keep unavailable distinct from retry")
    func partialResult() throws {
        let room = try RoomID("room-1")
        let other = try RoomID("room-2")
        let results: [V2RoomRecoveryResult] = [
            .states(.init(items: [.init(roomID: room, result: .unavailable),
                                  .init(roomID: other, result: .retry)])),
            .latestVisible(.init(items: [.init(roomID: room, result: .retry),
                                         .init(roomID: other, result: .unavailable)])),
        ]
        for result in results {
            #expect(try JSONDecoder().decode(V2RoomRecoveryResult.self,
                from: JSONEncoder().encode(result)) == result)
        }
    }
}
