import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("Room recovery batcher timer lifecycle")
struct V2RoomRecoveryBatcherLifecycleTests {
    @Test("completed user keys release all timer identity bookkeeping")
    func userChurnDoesNotRetainTimers() async throws {
        let owner = try V2RoomDataOwner(shardID: "room-a", epoch: 0)
        let token = V2RoomActivationToken(roomID: .init(uuid: UUID()), owner: owner,
            activationEpoch: try .init(1), host: .init(hostID: try .init("timer-host"), incarnationID: UUID()))
        let batcher = V2HostRoomRecoveryQueryBatcher(configuration: try .init()) { _, _ in
            throw V2RoomRecoveryReadError.corruptPersistence
        }
        for _ in 0..<24 {
            await #expect(throws: V2RoomRecoveryReadError.corruptPersistence) {
                _ = try await batcher.state(.init(token: token, actorUserID: .init(uuid: UUID()),
                    batchDeadline: .now + .milliseconds(2), callDeadline: .now + .seconds(2)))
            }
            #expect(await batcher.scheduledKeyCount == 0)
            #expect(await batcher.pendingCount == 0)
        }
    }
}
