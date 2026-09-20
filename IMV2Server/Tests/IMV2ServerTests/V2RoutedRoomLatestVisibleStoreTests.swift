import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("Latest visible owner routing")
struct V2RoutedRoomLatestVisibleStoreTests {
    @Test func missingRoomDoesNotHideTheAuthorizedRoom() async throws {
        let room = RoomID(uuid: UUID()), missing = RoomID(uuid: UUID())
        let store = V2RoutedRoomLatestVisibleStore(router: LatestVisibleRouter(room: room)) { _, ids, _ in
            #expect(ids == [room])
            return [room: .snapshot(try .init(roomID: room, ownerEpoch: 1, membershipRevision: 1, head: 0, latest: nil))]
        }
        let results = try await store.latestVisible(roomIDs: [room, missing], actorUserID: .init(uuid: UUID()))
        #expect(results.count == 2)
        #expect(results[missing] == .unavailable)
        guard case .snapshot? = results[room] else { Issue.record("authorized room was hidden"); return }
    }

    @Test(arguments: ["unchanged", "moved", "epoch", "wrongRoom", "missing", "unavailableMoved"])
    func fencesResults(mode: String) async throws {
        let room = RoomID(uuid: UUID())
        let router = LatestVisibleRouter(room: room)
        let store = V2RoutedRoomLatestVisibleStore(router: router) { _, ids, _ in
            #expect(ids == [room])
            if mode == "moved" || mode == "unavailableMoved" { await router.move() }
            if mode == "missing" { return [:] }
            if mode == "unavailableMoved" { return [room: .unavailable] }
            return [room: .snapshot(try .init(roomID: mode == "wrongRoom" ? .init(uuid: UUID()) : room,
                ownerEpoch: mode == "epoch" ? 0 : 1, membershipRevision: 1, head: 0, latest: nil))]
        }
        let result = try await store.latestVisible(roomIDs: [room, room], actorUserID: .init(uuid: UUID()))
        #expect(result.count == 1)
        if mode == "unchanged" {
            guard case .snapshot? = result[room] else { Issue.record("snapshot missing"); return }
        } else { #expect(result[room] == .retry) }
    }

    @Test func cancellationPropagatesInsteadOfBecomingRetry() async throws {
        let room = RoomID(uuid: UUID())
        let store = V2RoutedRoomLatestVisibleStore(router: LatestVisibleRouter(room: room)) { _, _, _ in
            throw CancellationError()
        }
        await #expect(throws: CancellationError.self) {
            try await store.latestVisible(roomIDs: [room], actorUserID: .init(uuid: UUID()))
        }
    }
}

private actor LatestVisibleRouter: V2RoomShardRouting {
    let room: RoomID
    private var moved = false
    init(room: RoomID) { self.room = room }
    func move() { moved = true }
    func route(for roomID: RoomID) throws -> V2RoomShardRoute {
        guard roomID == room else { throw V2RoomShardRouteError.roomNotFound }
        return try .init(shardID: moved ? "next" : "original", epoch: moved ? 2 : 1)
    }
    func routes(for roomIDs: [RoomID]) throws -> [RoomID: V2RoomShardRoute] {
        try Dictionary(uniqueKeysWithValues: roomIDs.map { ($0, try route(for: $0)) })
    }
}
