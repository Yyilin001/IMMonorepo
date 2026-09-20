import Foundation
import Testing
@testable import IMV2Server

@Suite("Room write batch route cache")
struct V2RoomWriteBatchRouteCacheTests {
    @Test("bounded LRU preserves advisory routes and evicts the least recent room")
    func boundedLRU() async {
        let cache = V2RoomWriteBatchRouteCache(capacity: 2)
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
        let third = UUID(uuidString: "00000000-0000-0000-0000-000000000103")!

        await cache.insert([
            (roomID: first, route: .individual),
            (roomID: second, route: .direct),
        ])
        #expect(await cache.values(for: [first]) == [.individual])

        await cache.insert([(roomID: third, route: .individual)])

        #expect(await cache.values(for: [first, second, third]) == [
            .individual, nil, .individual,
        ])
        let snapshot = await cache.snapshot()
        #expect(snapshot.entries == 2)
        #expect(snapshot.lookupHits == 3)
        #expect(snapshot.lookupMisses == 1)
        #expect(snapshot.insertions == 3)
        #expect(snapshot.evictions == 1)
    }

    @Test("refreshing an existing room updates its route without growing capacity")
    func refreshesExistingRoom() async {
        let cache = V2RoomWriteBatchRouteCache(capacity: 1)
        let room = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!

        await cache.insert([(roomID: room, route: .individual)])
        await cache.insert([(roomID: room, route: .large)])

        #expect(await cache.values(for: [room]) == [.large])
        let snapshot = await cache.snapshot()
        #expect(snapshot.entries == 1)
        #expect(snapshot.insertions == 1)
        #expect(snapshot.evictions == 0)
    }
}
