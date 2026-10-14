import Foundation
import Synchronization
import Testing
import IMV2Core
import IMV2ActorContracts
@testable import IMV2ServerGateway

@Suite("Trusted journal receiver and socket authority")
struct V2GatewayJournalProjectionReceiverTests {
    @Test("checkpoint diagnostics preserve denial boundaries and identify control versus expiry")
    func checkpointFailureReasons() {
        let f = Fixture(), time = Mutex(ContinuousClock.now), coverage = Mutex(true)
        let start = time.withLock { $0 }
        let receiver = V2GatewayJournalProjectionReceiver(projection: .init(), now: { time.withLock { $0 } })
        func result(_ cut: Int64 = 0) -> Result<Int64, V2GatewayJournalProjectionReceiver.RecoveryCheckpointFailure> {
            receiver.assessedRecoveryCheckpoint(source: f.source, fence: f.fence, minimumCut: cut)
        }
        #expect(result(-1) == .failure(.invalidCut))
        #expect(result() == .failure(.missingBinding))
        let installed = receiver.install(source: f.source, serviceID: "publisher", fence: f.fence,
            deadline: start + .seconds(10), rooms: [f.room], viewers: [f.user], current: { coverage.withLock { $0 } })
        #expect(installed)
        #expect(result() == .failure(.missingCheckpoint))
        let snapshot = f.snapshot()
        #expect(receiver.authorizeSnapshot(snapshot))
        guard case .applied = receiver.applyJournalProjection(snapshot, authenticatedServiceID: "publisher") else {
            Issue.record("baseline missing"); return
        }
        #expect(result() == .success(5))
        #expect(result(6) == .failure(.checkpointBehind))
        #expect(receiver.recoveryCheckpoint(source: f.source, fence: f.fence, minimumCut: 6) == nil)
        let changes = V2RealtimeJournalProjectionBatch(source: f.source, fence: f.fence,
            payload: .changes(fromExclusive: 5, throughInclusive: 6, entries: [
                .init(sequence: 6, change: .userControlInvalidation(userID: f.user, controlVersion: 8, deviceID: UUID()))
            ]))
        #expect(receiver.applyJournalProjection(changes, authenticatedServiceID: "publisher") == .snapshotRequired)
        #expect(result() == .failure(.pendingUserControls))
        coverage.withLock { $0 = false }
        #expect(result() == .failure(.coverageChanged))
        time.withLock { $0 = start + .seconds(11) }
        #expect(result() == .failure(.expired))
        receiver.shutdown()
        #expect(result() == .failure(.closed))
    }
    @Test("live room grants cannot outlive independent authentication coverage")
    func authenticationCoverageFencesActualWrites() {
        let f = Fixture(), time = Mutex(ContinuousClock.now)
        let start = time.withLock { $0 }
        let receiver = V2GatewayJournalProjectionReceiver(projection: .init(), now: { time.withLock { $0 } })
        #expect(receiver.configureAuthenticationSources(["auth-test"]))
        #expect(receiver.install(source: f.source, serviceID: "publisher", fence: f.fence,
            deadline: start + .seconds(10), rooms: [f.room], viewers: [f.user]))
        let roomSnapshot = f.snapshot()
        #expect(receiver.authorizeSnapshot(roomSnapshot))
        guard case .applied = receiver.applyJournalProjection(roomSnapshot, authenticatedServiceID: "publisher") else {
            Issue.record("room baseline failed"); return
        }
        let withoutAuthentication = receiver.enqueueAuthorized(roomID: f.room, userID: f.user, memberRevision: 1, enqueue: {})
        #expect(!withoutAuthentication)
        let auth = V2RealtimeJournalSource(sourceID: "auth-test", incarnationID: UUID(),
            partitionID: V2RealtimeTopicKey(kind: .userSync, id: f.user.rawValue).partitionID())
        #expect(receiver.install(source: auth, serviceID: "publisher", fence: f.fence,
            deadline: start + .seconds(1), rooms: [], viewers: []))
        #expect(receiver.installUserControlFloors(source: auth, fence: f.fence,
            versions: [f.user: 0], isAuthenticationSource: true))
        let authSnapshot = V2RealtimeJournalProjectionBatch(source: auth, fence: f.fence,
            payload: .snapshot(cut: 5, rooms: []))
        #expect(receiver.authorizeSnapshot(authSnapshot))
        guard case .applied = receiver.applyJournalProjection(authSnapshot, authenticatedServiceID: "publisher") else {
            Issue.record("auth baseline failed"); return
        }
        let accepted = receiver.enqueueAuthorized(roomID: f.room, userID: f.user, memberRevision: 1, enqueue: {})
        #expect(accepted)
        time.withLock { $0 = start + .seconds(2) }
        #expect(receiver.currentRoom(f.room) != nil)
        let expiredAuth = receiver.enqueueAuthorized(roomID: f.room, userID: f.user, memberRevision: 1, enqueue: {})
        #expect(!expiredAuth)
        #expect(receiver.authenticationBinding(userID: f.user) == nil)
    }
    @Test("continuous renewal preserves grants but expired coverage cannot revive them")
    func renewalPreservesOnlyContinuousAuthority() {
        let f = Fixture(), time = Mutex(ContinuousClock.now)
        let start = time.withLock { $0 }
        let receiver = V2GatewayJournalProjectionReceiver(projection: .init(), now: { time.withLock { $0 } })
        #expect(receiver.install(source: f.source, serviceID: "publisher", fence: f.fence,
                                 deadline: start + .seconds(2), rooms: [f.room], viewers: [f.user]))
        let snapshot = f.snapshot()
        #expect(receiver.authorizeSnapshot(snapshot))
        guard case .applied = receiver.applyJournalProjection(snapshot, authenticatedServiceID: "publisher") else {
            Issue.record("baseline failed"); return
        }
        time.withLock { $0 = start + .seconds(1) }
        let renewed = receiver.renew(source: f.source, serviceID: "publisher", fence: f.fence,
            deadline: start + .seconds(4), current: { true })
        #expect(renewed)
        time.withLock { $0 = start + .seconds(3) }
        let accepted = receiver.enqueueAuthorized(roomID: f.room, userID: f.user, memberRevision: 1, enqueue: {})
        #expect(accepted)
        time.withLock { $0 = start + .seconds(5) }
        let revived = receiver.renew(source: f.source, serviceID: "publisher", fence: f.fence,
            deadline: start + .seconds(8), current: { true })
        #expect(!revived)
        let refused = receiver.enqueueAuthorized(roomID: f.room, userID: f.user, memberRevision: 1, enqueue: {})
        #expect(!refused)
    }
    @Test("room recovery cannot acknowledge an uncovered user control")
    func userControlRequiresTrustedFloor() {
        let f = Fixture()
        let receiver = V2GatewayJournalProjectionReceiver(projection: .init())
        #expect(receiver.install(source: f.source, serviceID: "publisher", fence: f.fence,
                                 deadline: .now + .seconds(10), rooms: [f.room], viewers: [f.user]))
        let snapshot = f.snapshot()
        #expect(receiver.authorizeSnapshot(snapshot))
        guard case .applied = receiver.applyJournalProjection(snapshot, authenticatedServiceID: "publisher") else {
            Issue.record("initial snapshot missing"); return
        }
        let change = V2RealtimeJournalProjectionBatch(source: f.source, fence: f.fence,
            payload: .changes(fromExclusive: 5, throughInclusive: 6, entries: [
                .init(sequence: 6, change: .userControlInvalidation(userID: f.user, controlVersion: 8, deviceID: UUID()))
            ]))
        #expect(receiver.applyJournalProjection(change, authenticatedServiceID: "publisher") == .snapshotRequired)
        let blocked = receiver.enqueueAuthorized(roomID: f.room, userID: f.user, memberRevision: 1, enqueue: {})
        #expect(!blocked)
        #expect(receiver.applyJournalProjection(snapshot, authenticatedServiceID: "publisher") == .snapshotRequired)
        #expect(receiver.installUserControlFloors(source: f.source, fence: f.fence, versions: [f.user: 7]))
        #expect(receiver.applyJournalProjection(snapshot, authenticatedServiceID: "publisher") == .snapshotRequired)
        #expect(receiver.installUserControlFloors(source: f.source, fence: f.fence, versions: [f.user: 8]))
        #expect(!receiver.installUserControlFloors(source: f.source, fence: f.fence, versions: [f.user: 7]))
    }
    private struct Fixture {
        let room = RoomID(uuid: UUID())
        let user = UserID(uuid: UUID())
        let source = V2RealtimeJournalSource(sourceID: "source-test", incarnationID: UUID(), partitionID: 2)
        let fence = V2RealtimeJournalProjectionFence(publisherIncarnationID: UUID(), sourceLeaseEpoch: 1,
            sourceLeaseToken: UUID(), sourceLeaseExpiresAt: .distantFuture, routingPartitionEpoch: 1,
            routingLeaseToken: UUID(), sessionID: UUID(), interestGeneration: 1, gatewayIncarnationID: UUID())
        func snapshot(head: UInt64 = 3) -> V2RealtimeJournalProjectionBatch {
            .init(source: source, fence: fence, payload: .snapshot(cut: 5, rooms: [
                .init(roomID: room, ownerEpoch: 1, permissionVersion: 2, controlVersion: 2,
                      viewerMembershipRevisions: [user: 1], highWatermark: head)
            ]))
        }
    }

    @Test("only the installed service can apply the exact locally authorized snapshot")
    func exactSnapshotAndService() {
        let f = Fixture(), projection = V2RealtimeJournalSharedProjection()
        let receiver = V2GatewayJournalProjectionReceiver(projection: projection)
        #expect(receiver.install(source: f.source, serviceID: "publisher", fence: f.fence,
                                 deadline: .now + .seconds(10), rooms: [f.room], viewers: [f.user]))
        let snapshot = f.snapshot()
        #expect(receiver.applyJournalProjection(snapshot, authenticatedServiceID: "publisher") == .stale)
        #expect(receiver.authorizeSnapshot(snapshot))
        #expect(receiver.applyJournalProjection(snapshot, authenticatedServiceID: "other") == .stale)
        #expect(receiver.applyJournalProjection(f.snapshot(head: 30), authenticatedServiceID: "publisher") == .stale)
        guard case .applied(let receipt) = receiver.applyJournalProjection(snapshot, authenticatedServiceID: "publisher") else {
            Issue.record("trusted snapshot did not commit"); return
        }
        #expect(receipt.snapshotInstalled && receipt.appliedThrough == 5)
        let writes = Mutex(0)
        let enqueueResult1 = receiver.enqueueAuthorized(roomID: f.room, userID: f.user, memberRevision: 1,
                                          enqueue: { writes.withLock { $0 += 1 } })
        #expect(enqueueResult1)
        let enqueueResult2 = !receiver.enqueueAuthorized(roomID: f.room, userID: f.user, memberRevision: 2,
                                           enqueue: { writes.withLock { $0 += 1 } })
        #expect(enqueueResult2)
        receiver.retire(source: f.source)
        let enqueueResult3 = !receiver.enqueueAuthorized(roomID: f.room, userID: f.user, memberRevision: 1,
                                           enqueue: { writes.withLock { $0 += 1 } })
        #expect(enqueueResult3)
        #expect(writes.withLock { $0 } == 1)
    }

    @Test("wire future expiry cannot extend local monotonic authority")
    func monotonicExpiryAndShutdown() {
        let f = Fixture(), time = Mutex(ContinuousClock.now)
        let start = time.withLock { $0 }
        let receiver = V2GatewayJournalProjectionReceiver(projection: .init(), now: { time.withLock { $0 } })
        #expect(receiver.install(source: f.source, serviceID: "publisher", fence: f.fence,
                                 deadline: start + .seconds(1), rooms: [f.room], viewers: [f.user]))
        let snapshot = f.snapshot()
        #expect(receiver.authorizeSnapshot(snapshot))
        time.withLock { $0 = start + .seconds(2) }
        #expect(receiver.applyJournalProjection(snapshot, authenticatedServiceID: "publisher") == .stale)
        let enqueueResult4 = !receiver.enqueueAuthorized(roomID: f.room, userID: f.user, memberRevision: nil, enqueue: {})
        #expect(enqueueResult4)
        receiver.shutdown()
        #expect(!receiver.install(source: f.source, serviceID: "publisher", fence: f.fence,
                                  deadline: start + .seconds(10), rooms: [f.room], viewers: [f.user]))
    }

    @Test("renewing after an authority gap requires a fresh trusted snapshot")
    func renewalGapRequiresSnapshot() {
        let f = Fixture(), time = Mutex(ContinuousClock.now)
        let start = time.withLock { $0 }
        let receiver = V2GatewayJournalProjectionReceiver(projection: .init(), now: { time.withLock { $0 } })
        #expect(receiver.install(source: f.source, serviceID: "publisher", fence: f.fence,
                                 deadline: start + .seconds(1), rooms: [f.room], viewers: [f.user]))
        let snapshot = f.snapshot()
        #expect(receiver.authorizeSnapshot(snapshot))
        guard case .applied = receiver.applyJournalProjection(snapshot, authenticatedServiceID: "publisher") else {
            Issue.record("initial snapshot did not commit"); return
        }
        time.withLock { $0 = start + .seconds(2) }
        #expect(receiver.install(source: f.source, serviceID: "publisher", fence: f.fence,
                                 deadline: start + .seconds(10), rooms: [f.room], viewers: [f.user]))
        let afterGap = receiver.enqueueAuthorized(roomID: f.room, userID: f.user, memberRevision: 1, enqueue: {})
        #expect(!afterGap)
        #expect(receiver.applyJournalProjection(snapshot, authenticatedServiceID: "publisher") == .stale)
        #expect(receiver.authorizeSnapshot(snapshot))
        guard case .applied = receiver.applyJournalProjection(snapshot, authenticatedServiceID: "publisher") else {
            Issue.record("freshly authorized snapshot did not commit"); return
        }
        let renewed = receiver.enqueueAuthorized(roomID: f.room, userID: f.user, memberRevision: 1, enqueue: {})
        #expect(renewed)
    }

    @Test("withdrawn partition coverage denies an already captured writer permit")
    func coverageWithdrawalDeniesCapturedWrite() {
        let f = Fixture(), coverage = Mutex(true)
        let receiver = V2GatewayJournalProjectionReceiver(projection: .init())
        let installed = receiver.install(source: f.source, serviceID: "publisher", fence: f.fence,
            deadline: .now + .seconds(10), rooms: [f.room], viewers: [f.user], current: { coverage.withLock { $0 } })
        #expect(installed)
        let snapshot = f.snapshot()
        #expect(receiver.authorizeSnapshot(snapshot))
        guard case .applied = receiver.applyJournalProjection(snapshot, authenticatedServiceID: "publisher"),
              let captured = receiver.captureRoom(f.room) else {
            Issue.record("initial capture failed"); return
        }
        coverage.withLock { $0 = false }
        let writes = Mutex(0)
        let accepted = receiver.enqueueAuthorized(roomID: f.room, userID: f.user, memberRevision: 1,
            expectedSource: captured.source, expectedFence: captured.fence,
            enqueue: { writes.withLock { $0 += 1 } })
        #expect(!accepted)
        #expect(writes.withLock { $0 } == 0)
        #expect(receiver.currentRoom(f.room) == nil)
    }
}
