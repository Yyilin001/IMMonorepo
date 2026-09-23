import Foundation
import IMV2ActorContracts
import IMV2Core
import Synchronization
@testable import IMV2Server
import Testing

@Suite("Room recovery batcher timer lifecycle")
struct V2RoomRecoveryBatcherLifecycleTests {
    @Test("a recovery batch uses its earliest call deadline, not its timer cutoff")
    func earliestSelectedSQLDeadline() async throws {
        let owner = try V2RoomDataOwner(shardID: "room-a", epoch: 0)
        let host = V2ActorHostIdentity(hostID: try .init("timer-host"), incarnationID: UUID())
        let firstToken = V2RoomActivationToken(roomID: .init(uuid: UUID()), owner: owner,
            activationEpoch: try .init(1), host: host)
        let secondToken = V2RoomActivationToken(roomID: .init(uuid: UUID()), owner: owner,
            activationEpoch: try .init(1), host: host)
        let observed = Mutex<[ContinuousClock.Instant?]>([])
        let batcher = V2HostRoomRecoveryQueryBatcher(configuration: try .init(maximumItems: 2)) { _, _ in
            observed.withLock { $0.append(V2RoomSQLDeadline.current) }
            throw V2RoomRecoveryReadError.corruptPersistence
        }
        let actor = UserID(uuid: UUID())
        let earlier = ContinuousClock.now + .seconds(2)
        let later = earlier + .seconds(2)
        let first = Task { try await batcher.state(.init(token: firstToken, actorUserID: actor,
            batchDeadline: later, callDeadline: earlier)) }
        for _ in 0..<100 {
            if await batcher.pendingCount == 1 { break }
            await Task.yield()
        }
        #expect(await batcher.pendingCount == 1)
        let second = Task { try await V2RoomSQLDeadline.withSelectedDeadline(later + .seconds(5)) {
            try await batcher.state(.init(token: secondToken, actorUserID: actor,
                batchDeadline: later, callDeadline: later))
        } }
        await #expect(throws: V2RoomRecoveryReadError.corruptPersistence) { try await first.value }
        await #expect(throws: V2RoomRecoveryReadError.corruptPersistence) { try await second.value }
        #expect(observed.withLock { $0 } == [earlier])
    }

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
