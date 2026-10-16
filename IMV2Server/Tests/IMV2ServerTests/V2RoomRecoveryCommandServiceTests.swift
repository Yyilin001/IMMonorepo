@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing
@testable import IMV2ServerGateway

@Suite("Room recovery command boundary")
struct V2RoomRecoveryCommandServiceTests {
    @Test("state, unavailable and retry remain distinct on the wire")
    func explicitResults() async throws {
        let ids = (0..<3).map { _ in RoomID(uuid: UUID()) }
        let state = try V2RoomSynchronizationState(roomID: ids[0], ownerEpoch: 1,
            viewerMembershipRevision: 1, head: 10, trimmedThrough: 0,
            readThrough: 3, latestOwnMessageSequence: 5)
        let reader = CommandStateFixture(values: [ids[0]: .state(state), ids[1]: .unavailable, ids[2]: .retry])
        var request = IMV2RoomSyncStateBatch()
        request.roomIds = ids.map(\.rawValue)
        let response = try await makeService(reader).batch(request, actorUserID: .init(uuid: UUID()))
        let rooms = response.roomSyncStateBatchResult.rooms
        #expect(rooms.map(\.roomID) == ids.map(\.rawValue))
        #expect(rooms[0].state.unreadCount == 5)
        #expect(rooms[0].state.head == 10)
        #expect(rooms[1].result == .unavailable(.init()))
        guard case .retry? = rooms[2].result else {
            Issue.record("Expected an explicit retry result")
            return
        }
        #expect(rooms[2].retry.retryAfterSeconds > 0)
    }

    @Test("invalid batches never reach persistence", arguments: [0, 101, 2])
    func invalidRequest(count: Int) async throws {
        let reader = CommandStateFixture(values: [:])
        var request = IMV2RoomSyncStateBatch()
        request.roomIds = Array(repeating: UUID().uuidString, count: count)
        let service = try makeService(reader)
        await #expect(throws: V2RoomRecoveryReadError.invalidRequest) {
            try await service.batch(request, actorUserID: .init(uuid: UUID()))
        }
        #expect(await reader.calls == 0)
    }

    @Test("missing state results fail instead of reporting a complete batch")
    func incompleteBatch() async throws {
        let service = try makeService(CommandStateFixture(values: [:]))
        var request = IMV2RoomSyncStateBatch()
        request.roomIds = [UUID().uuidString]
        await #expect(throws: V2RoomRecoveryReadError.corruptPersistence) {
            try await service.batch(request, actorUserID: .init(uuid: UUID()))
        }
    }

    private func makeService(_ reader: CommandStateFixture) throws -> V2RoomRecoveryCommandService {
        let source = CommandTopologyFixture()
        let directory = V2UserRoomDirectoryService(snapshotSource: source,
            cursorCodec: try .init(key: Data(repeating: 1, count: 32)))
        return try .init(directory: directory, states: reader, latestVisible: .init(reader: reader))
    }
}

private actor CommandStateFixture: V2RoomStateReading, V2RoomLatestVisibleReading {
    func latestVisible(roomIDs: [RoomID], actorUserID: UserID) async throws -> [RoomID: V2RoomLatestVisibleResult] {
        throw V2RoomRecoveryReadError.invalidRequest
    }
    let values: [RoomID: V2RoomStateReadResult]
    private(set) var calls = 0
    init(values: [RoomID: V2RoomStateReadResult]) { self.values = values }
    func states(roomIDs: [RoomID], actorUserID: UserID) async throws -> [RoomID: V2RoomStateReadResult] {
        calls += 1
        return values
    }
}

private struct CommandDirectoryFixture: V2UserRoomDirectoryReading {
    func rooms(actorUserID: UserID, after: RoomID?, limit: Int) async throws -> V2UserRoomDirectorySlice {
        .init(entries: [], scannedThrough: nil, hasMore: false)
    }
}

private struct CommandTopologyFixture: V2RoomRecoveryDirectoryReading {
    let storeCount = 1
    func snapshot(actorUserID: UserID, after: RoomID?, limit: Int, storeIndex: Int) async throws -> V2RoomRecoveryDirectorySnapshot {
        try await .init(generation: "1", slice: CommandDirectoryFixture().rooms(actorUserID: actorUserID, after: after, limit: limit))
    }
}
