import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("Room directory owner validation")
struct V2OwnerValidatedRoomDirectoryStoreTests {
    @Test("migration copies are filtered without losing continuation")
    func filtersCopies() async throws {
        let entry = try makeEntry()
        let store = try makeStore(entry, route: .init(shardID: "other", epoch: 2))
        let page = try await store.rooms(actorUserID: .init(uuid: UUID()), after: nil, limit: 10)
        #expect(page.entries.isEmpty)
        #expect(page.scannedThrough == entry.roomID)
        #expect(page.hasMore)
    }

    @Test("logical shards sharing a physical store remain eligible")
    func physicalAliases() async throws {
        let entry = try makeEntry()
        let store = try makeStore(entry, route: .init(shardID: "alias", epoch: 1))
        let page = try await store.rooms(actorUserID: .init(uuid: UUID()), after: nil, limit: 10)
        #expect(page.entries == [entry])
    }

    @Test("an owner epoch mismatch invalidates the page")
    func epochMismatch() async throws {
        let store = try makeStore(makeEntry(), route: .init(shardID: "owner", epoch: 2))
        await #expect(throws: V2RoomRecoveryReadError.topologyChanged) {
            try await store.rooms(actorUserID: .init(uuid: UUID()), after: nil, limit: 10)
        }
    }

    @Test("an incomplete route response cannot silently skip membership")
    func missingRoute() async throws {
        let store = try makeStore(makeEntry(), route: nil)
        await #expect(throws: V2RoomRecoveryReadError.corruptPersistence) {
            try await store.rooms(actorUserID: .init(uuid: UUID()), after: nil, limit: 10)
        }
    }

    private func makeEntry() throws -> V2UserRoomDirectoryEntry {
        try .init(roomID: .init(uuid: UUID()), roomKind: .group,
                  viewerMembershipRevision: 1, ownerEpoch: 1)
    }

    private func makeStore(_ entry: V2UserRoomDirectoryEntry, route: V2RoomShardRoute?) throws -> V2OwnerValidatedRoomDirectoryStore {
        try .init(underlying: OwnerDirectoryFixture(entry: entry),
                  router: OwnerRouteFixture(route: route), physicalStoreShardIDs: ["owner", "alias"])
    }
}

private struct OwnerDirectoryFixture: V2UserRoomDirectoryReading {
    let entry: V2UserRoomDirectoryEntry
    func rooms(actorUserID: UserID, after: RoomID?, limit: Int) async throws -> V2UserRoomDirectorySlice {
        .init(entries: [entry], scannedThrough: entry.roomID, hasMore: true)
    }
}

private struct OwnerRouteFixture: V2RoomShardRouting {
    let route: V2RoomShardRoute?
    func route(for roomID: RoomID) async throws -> V2RoomShardRoute {
        guard let route else { throw V2RoomShardRouteError.roomNotFound }
        return route
    }
    func routes(for roomIDs: [RoomID]) async throws -> [RoomID: V2RoomShardRoute] {
        guard let route else { return [:] }
        return Dictionary(uniqueKeysWithValues: roomIDs.map { ($0, route) })
    }
}
