@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core
import Synchronization
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("Room recovery batcher timer lifecycle")
struct V2RoomRecoveryBatcherLifecycleTests {
    @Test("two granted room turns share one Host SQL read permit")
    func onePermitPerRecoveryBatch() async throws {
        let admission = V2DatabaseWorkAdmissionController(policy: .init(
            maximumForegroundWriteInFlight: 1, maximumInteractiveReadInFlight: 1,
            maximumSyncInFlight: 1, maximumForegroundWriteQueued: 1,
            maximumInteractiveReadQueued: 1, maximumSyncQueued: 1,
            timeout: .seconds(1)))
        let owner = try V2RoomDataOwner(shardID: "room-a", epoch: 0)
        let host = V2ActorHostIdentity(hostID: try .init("batch-host"), incarnationID: UUID())
        let tokens = (0..<2).map { _ in V2RoomActivationToken(roomID: .init(uuid: UUID()),
            owner: owner, activationEpoch: try! .init(1), host: host) }
        let observed = Mutex<Int>(0)
        let batcher = V2HostRoomRecoveryQueryBatcher(configuration: try .init(maximumItems: 2),
            databaseWorkAdmission: admission) { _, actual in
            #expect(actual.count == 2)
            observed.withLock { $0 += 1 }
            throw V2RoomRecoveryReadError.corruptPersistence
        }
        let actor = UserID(uuid: UUID())
        let deadline = ContinuousClock.now + .seconds(2)
        let first = Task { try await batcher.state(.init(token: tokens[0], actorUserID: actor,
            batchDeadline: deadline, callDeadline: deadline)) }
        defer { first.cancel() }
        try await waitForFirstPendingCall(batcher)
        let second = Task { try await batcher.state(.init(token: tokens[1], actorUserID: actor,
            batchDeadline: deadline, callDeadline: deadline)) }
        defer { second.cancel() }
        await #expect(throws: V2RoomRecoveryReadError.corruptPersistence) { try await first.value }
        await #expect(throws: V2RoomRecoveryReadError.corruptPersistence) { try await second.value }
        #expect(observed.withLock { $0 } == 1)
        let snapshot = await admission.snapshot()
        #expect(snapshot.interactiveRead.admittedRequests == 1)
        #expect(snapshot.interactiveRead.inFlight == 0)
    }

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
        defer { first.cancel() }
        try await waitForFirstPendingCall(batcher)
        let second = Task { try await V2RoomSQLDeadline.withSelectedDeadline(later + .seconds(5)) {
            try await batcher.state(.init(token: secondToken, actorUserID: actor,
                batchDeadline: later, callDeadline: later))
        } }
        defer { second.cancel() }
        await #expect(throws: V2RoomRecoveryReadError.corruptPersistence) { try await first.value }
        await #expect(throws: V2RoomRecoveryReadError.corruptPersistence) { try await second.value }
        #expect(observed.withLock { $0 } == [earlier])
    }

    private func waitForFirstPendingCall(_ batcher: V2HostRoomRecoveryQueryBatcher) async throws {
        // A fixed number of yields does not establish that another task has
        // entered the actor, especially on the bounded Linux CI executor.
        let deadline = ContinuousClock.now + .seconds(1)
        while await batcher.pendingCount != 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await batcher.pendingCount == 1)
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
