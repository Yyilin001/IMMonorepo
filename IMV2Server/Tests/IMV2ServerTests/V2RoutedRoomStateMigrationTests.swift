import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("Room state owner changes during reads")
struct V2RoutedRoomStateMigrationTests {
    @Test(arguments: [false, true], [false, true])
    func oldOwnerObservationIsFenced(moved: Bool, unavailable: Bool) async throws {
        let room = RoomID(uuid: UUID())
        let old = try V2RoomShardRoute(shardID: "old", epoch: 1)
        let new = try V2RoomShardRoute(shardID: "new", epoch: 2)
        let router = StateMigrationRouter(current: old)
        let state = try V2RoomSynchronizationState(roomID: room, ownerEpoch: 1, viewerMembershipRevision: 1,
            head: 7, trimmedThrough: 0, readThrough: 0, latestOwnMessageSequence: 0)
        let reader = V2RoutedRoomStateStore(router: router) { shard, rooms, _ in
            #expect(shard == "old" && rooms == [room])
            if moved { await router.change(to: new) }
            return [room: unavailable ? .unavailable : .state(state)]
        }
        let result = try await reader.states(roomIDs: [room], actorUserID: .init(uuid: UUID()))
        if moved {
            guard case .retry? = result[room] else { Issue.record("Old owner result escaped after routing changed"); return }
        } else if unavailable {
            guard case .unavailable? = result[room] else { Issue.record("Stable absence must remain explicit"); return }
        } else {
            guard case .state(let value)? = result[room] else { Issue.record("Stable state must remain readable"); return }
            #expect(value == state)
        }
    }
}

private actor StateMigrationRouter: V2RoomShardRouting {
    var current: V2RoomShardRoute
    init(current: V2RoomShardRoute) { self.current = current }
    func route(for roomID: RoomID) async throws -> V2RoomShardRoute { current }
    func change(to route: V2RoomShardRoute) { current = route }
}
