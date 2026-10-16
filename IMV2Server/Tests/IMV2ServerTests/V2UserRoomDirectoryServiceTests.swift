@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("Bounded physical-store room directory")
struct V2UserRoomDirectoryServiceTests {
    @Test("an empty physical store continues to the next without reading it early")
    func emptyStore() async throws {
        let first = DirectoryStoreProbe(), second = DirectoryStoreProbe()
        let topology = DirectoryTopologyProbe(generation: "a", stores: [first, second])
        let service = try makeService(topology)
        let user = UserID(uuid: UUID())
        let page = try await service.list(actorUserID: user, cursor: nil, pageSize: 10)
        #expect(page.rooms.isEmpty && page.nextCursor != nil)
        #expect(await first.calls == 1)
        #expect(await second.calls == 0)
        let last = try await service.list(actorUserID: user, cursor: page.nextCursor, pageSize: 10)
        #expect(last.rooms.isEmpty && last.nextCursor == nil)
        #expect(await second.calls == 1)
    }

    @Test("a topology change during a physical read invalidates its page")
    func concurrentTopologyChange() async throws {
        let store = DirectoryStoreProbe()
        let topology = DirectoryTopologyProbe(generation: "a", stores: [store])
        let service = try makeService(DirectoryTopologyProbe(generation: "a", stores: [store], changesAfterFirstRead: true))
        await #expect(throws: V2RoomRecoveryReadError.topologyChanged) {
            try await service.list(actorUserID: .init(uuid: UUID()), cursor: nil, pageSize: 10)
        }
        #expect(await store.calls == 1)
    }

    private func makeService(_ topology: any V2RoomRecoveryDirectoryReading) throws -> V2UserRoomDirectoryService {
        .init(snapshotSource: topology, cursorCodec: try .init(key: Data(repeating: 7, count: 32)))
    }
}

private actor DirectoryStoreProbe: V2UserRoomDirectoryReading {
    private(set) var calls = 0
    func rooms(actorUserID: UserID, after: RoomID?, limit: Int) async throws -> V2UserRoomDirectorySlice {
        calls += 1
        return .init(entries: [], scannedThrough: nil, hasMore: false)
    }
}

private actor DirectoryTopologyProbe: V2RoomRecoveryDirectoryReading {
    nonisolated let storeCount: Int
    let generation: String
    let stores: [any V2UserRoomDirectoryReading]
    let changesAfterFirstRead: Bool
    var calls = 0
    init(generation: String, stores: [any V2UserRoomDirectoryReading], changesAfterFirstRead: Bool = false) {
        self.generation = generation; self.stores = stores; self.storeCount = stores.count
        self.changesAfterFirstRead = changesAfterFirstRead
    }
    func snapshot(actorUserID: UserID, after: RoomID?, limit: Int, storeIndex: Int) async throws -> V2RoomRecoveryDirectorySnapshot {
        calls += 1
        let page = try await stores[storeIndex].rooms(actorUserID: actorUserID, after: after, limit: limit)
        if changesAfterFirstRead { throw V2RoomRecoveryReadError.topologyChanged }
        return try .init(generation: generation, slice: page)
    }
}
