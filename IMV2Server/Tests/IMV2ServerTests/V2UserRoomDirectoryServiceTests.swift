import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("Bounded physical-store room directory")
struct V2UserRoomDirectoryServiceTests {
    @Test("an empty physical store continues to the next without reading it early")
    func emptyStore() async throws {
        let first = DirectoryStoreProbe(), second = DirectoryStoreProbe()
        let topology = try V2RoomRecoveryTopology(generation: "a", stores: [first, second])
        let service = try makeService(DirectoryTopologyProbe(value: topology))
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
        let topology = try V2RoomRecoveryTopology(generation: "a", stores: [store])
        let service = try makeService(DirectoryTopologyProbe(value: topology, changesAfterFirstRead: true))
        await #expect(throws: V2RoomRecoveryReadError.topologyChanged) {
            try await service.list(actorUserID: .init(uuid: UUID()), cursor: nil, pageSize: 10)
        }
        #expect(await store.calls == 1)
    }

    private func makeService(_ topology: any V2RoomRecoveryTopologyReading) throws -> V2UserRoomDirectoryService {
        .init(topologySource: topology, cursorCodec: try .init(key: Data(repeating: 7, count: 32)))
    }
}

private actor DirectoryStoreProbe: V2UserRoomDirectoryReading {
    private(set) var calls = 0
    func rooms(actorUserID: UserID, after: RoomID?, limit: Int) async throws -> V2UserRoomDirectorySlice {
        calls += 1
        return .init(entries: [], scannedThrough: nil, hasMore: false)
    }
}

private actor DirectoryTopologyProbe: V2RoomRecoveryTopologyReading {
    let value: V2RoomRecoveryTopology
    let changesAfterFirstRead: Bool
    var calls = 0
    init(value: V2RoomRecoveryTopology, changesAfterFirstRead: Bool = false) {
        self.value = value
        self.changesAfterFirstRead = changesAfterFirstRead
    }
    func topology() async throws -> V2RoomRecoveryTopology {
        calls += 1
        if changesAfterFirstRead && calls > 1 { return try .init(generation: "b", stores: value.stores) }
        return value
    }
}
