@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
import Testing
@testable import IMV2Server
@testable import IMV2ServerInfrastructure

@Suite("Hybrid-group shard credit snapshot cache")
struct V2HybridGroupShardCreditSnapshotCacheTests {
    @Test("bounded cache evicts the least recently used room and preserves order")
    func boundedLRU() async throws {
        let cache = V2HybridGroupShardCreditSnapshotCache(capacity: 2)
        let first = UUID()
        let second = UUID()
        let third = UUID()

        await cache.insert([
            .init(roomID: first, entry: try entry(shard: "rooms-load-00")),
            .init(roomID: second, entry: try entry(shard: "rooms-load-01")),
        ])
        let firstHit = await cache.values(for: [first])
        #expect(firstHit[0]?.roomShardID == "rooms-load-00")

        await cache.insert([
            .init(roomID: third, entry: try entry(shard: "rooms-load-02")),
        ])
        let values = await cache.values(for: [first, second, third])
        #expect(values[0]?.roomShardID == "rooms-load-00")
        #expect(values[1] == nil)
        #expect(values[2]?.roomShardID == "rooms-load-02")
    }

    @Test("explicit invalidation removes only the selected room")
    func invalidatesSelectedRoom() async throws {
        let cache = V2HybridGroupShardCreditSnapshotCache(capacity: 2)
        let first = UUID()
        let second = UUID()
        await cache.insert([
            .init(roomID: first, entry: try entry(shard: "rooms-load-00")),
            .init(roomID: second, entry: try entry(shard: "rooms-load-01")),
        ])

        await cache.invalidate([first])

        let values = await cache.values(for: [first, second])
        #expect(values[0] == nil)
        #expect(values[1]?.roomShardID == "rooms-load-01")
    }

    private func entry(
        shard: String
    ) throws -> V2HybridGroupShardCreditSnapshotCache.Entry {
        let leaseID = UUID()
        return .init(
            roomShardID: shard,
            capacityProfileID: "loadtest-v18",
            kind: "group",
            capacityClass: .large,
            frozenAt: nil,
            roomShardLeaseID: leaseID,
            roomShardLeaseGeneration: 1,
            shardState: try .init(
                lease: .init(
                    id: .init(leaseID.uuidString),
                    generation: 1,
                    validUntil: Date().addingTimeInterval(60),
                    commandWindow: .init(limit: 1_000_000)))
        )
    }
}
