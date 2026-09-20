import Foundation
import IMV2Core
@testable import IMV2Server
import SwiftProtobuf
import Testing

@Suite("Latest visible response budget")
struct V2RoomLatestVisibleCommandServiceTests {
    @Test func boundedResponseKeepsEveryRequestedIdentity() async throws {
        let ids = (0..<100).map { _ in RoomID(uuid: UUID()) }
        let values = try Dictionary(uniqueKeysWithValues: ids.map { id in
            (id, V2RoomLatestVisibleResult.snapshot(try .init(roomID: id, ownerEpoch: 1, membershipRevision: 1,
                head: 2, latest: .init(id: .init(uuid: UUID()), senderID: .init(uuid: UUID()), sequence: 1,
                    revision: 1, preview: String(repeating: "😀", count: 128), mediaCount: 0, createdAt: .now))))
        })
        let service = try V2RoomLatestVisibleCommandService(reader: LatestCommandFixture(values: values), maximumResponseBytes: 8192)
        var request = IMV2RoomLatestVisibleBatch(); request.roomIds = ids.map(\.rawValue)
        let response = try await service.batch(request, actorUserID: .init(uuid: UUID()))
        #expect(try response.serializedData().count <= 8192)
        let rooms = response.roomLatestVisibleBatchResult.rooms
        #expect(rooms.map(\.roomID) == ids.map(\.rawValue))
        #expect(rooms.contains { if case .snapshot? = $0.result { true } else { false } })
        #expect(rooms.contains { if case .retry? = $0.result { true } else { false } })
    }

    @Test func incompleteResultsFailBeforeEncoding() async throws {
        let service = try V2RoomLatestVisibleCommandService(reader: LatestCommandFixture(values: [:]))
        var request = IMV2RoomLatestVisibleBatch(); request.roomIds = [UUID().uuidString]
        let captured = request
        await #expect(throws: V2RoomRecoveryReadError.corruptPersistence) {
            try await service.batch(captured, actorUserID: .init(uuid: UUID()))
        }
    }
}

private struct LatestCommandFixture: V2RoomLatestVisibleReading {
    let values: [RoomID: V2RoomLatestVisibleResult]
    func latestVisible(roomIDs: [RoomID], actorUserID: UserID) async throws -> [RoomID: V2RoomLatestVisibleResult] { values }
}
