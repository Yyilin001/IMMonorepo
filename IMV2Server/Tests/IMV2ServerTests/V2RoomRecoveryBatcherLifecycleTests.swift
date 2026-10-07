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
        let entered = RecoveryExecutionGate(), release = RecoveryExecutionGate()
        defer { Task { await release.signal() } }
        let batcher = V2HostRoomRecoveryQueryBatcher(configuration: try .init(maximumItems: 2, maximumInFlightBatches: 1),
            databaseWorkAdmission: admission, executeStates: { actual in
                #expect(actual.count == 2)
                #expect(Set(actual.map(\.actorUserID)).count == 2)
                observed.withLock { $0 += 1 }
                await entered.signal()
                await release.wait()
                throw V2RoomRecoveryReadError.corruptPersistence
            }, execute: { _, _ in
                Issue.record("state collection must not call the single-viewer executor")
                throw V2RoomRecoveryReadError.corruptPersistence
            })
        let actor = UserID(uuid: UUID())
        let deadline = ContinuousClock.now + .seconds(2)
        let first = Task { try await batcher.state(.init(token: tokens[0], actorUserID: actor,
            batchDeadline: deadline, callDeadline: deadline)) }
        defer { first.cancel() }
        try await waitForFirstPendingCall(batcher)
        let secondActor = UserID(uuid: UUID())
        let second = Task { try await batcher.state(.init(token: tokens[1], actorUserID: secondActor,
            batchDeadline: deadline, callDeadline: deadline)) }
        defer { second.cancel() }
        await entered.wait()
        first.cancel()
        #expect(await admission.snapshot().interactiveRead.inFlight == 1)
        #expect(observed.withLock { $0 } == 1)
        let held = batcher.pressureSnapshot().purposes[.scalar]!
        #expect(held.inFlight == 1 && held.items == 2 && held.completed == 0)
        let queuedCoverage = Task {
            try await batcher.states([.init(token: tokens[0], actorUserID: actor,
                batchDeadline: deadline, callDeadline: deadline)])
        }
        try await waitForFirstPendingCall(batcher)
        #expect(await batcher.collectorSnapshot().retainedItems == 3)
        queuedCoverage.cancel()
        await #expect(throws: CancellationError.self) { try await queuedCoverage.value }
        let rejected = batcher.pressureSnapshot().purposes[.statesCohort]!
        #expect(rejected.busyBeforeAcquire == 0 && rejected.started == 0 && rejected.inFlight == 0)
        await release.signal()
        await #expect(throws: V2RoomRecoveryReadError.corruptPersistence) { try await first.value }
        await #expect(throws: V2RoomRecoveryReadError.corruptPersistence) { try await second.value }
        #expect(observed.withLock { $0 } == 1)
        let snapshot = await admission.snapshot()
        #expect(snapshot.interactiveRead.admittedRequests == 1)
        #expect(snapshot.interactiveRead.inFlight == 0)
        #expect(await batcher.scheduledKeyCount == 0)
        let settled = batcher.pressureSnapshot().purposes[.scalar]!
        #expect(settled.inFlight == 0 && settled.items == 0 && settled.completed == 1)
        #expect(settled.durationMillisecondsSum > 0 && settled.durationMillisecondsMax > 0)
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

    @Test("response budgets charge duplicate replies and preserve per-pair failures", arguments: [false, true])
    func responseBudgetUsesActualItems(perPairFailure: Bool) async throws {
        let owner = try V2RoomDataOwner(shardID: "room-a", epoch: 0)
        let token = V2RoomActivationToken(roomID: .init(uuid: UUID()), owner: owner,
            activationEpoch: try .init(1), host: .init(hostID: try .init("budget-host"), incarnationID: UUID()))
        let viewer = UserID(uuid: UUID()), other = UserID(uuid: UUID())
        let state = V2RoomStateReadResult.state(try .init(roomID: token.roomID, ownerEpoch: 0,
            viewerMembershipRevision: 1, head: 0, trimmedThrough: 0, readThrough: 0, latestOwnMessageSequence: 0))
        let count = perPairFailure ? 2 : 5
        let batcher = V2HostRoomRecoveryQueryBatcher(configuration: try .init(maximumItems: count,
            maximumResponseBytes: 1024), executeStates: { turns in
                #expect(turns.count == count)
                let key = V2RoomStateReadKey(roomID: token.roomID, viewerUserID: viewer)
                if perPairFailure {
                    return [key: .failure(RecoveryFixtureFailure(detail: String(repeating: "x", count: 4096))),
                            .init(roomID: token.roomID, viewerUserID: other): .success(state)]
                }
                return [key: .success(state)]
            }, execute: { _, _ in throw V2HostRoomRecoveryBatchError.corruptResult })
        let deadline = ContinuousClock.now + .seconds(3)
        let tasks = (0..<count).map { index in Task {
            try await batcher.state(.init(token: token, actorUserID: perPairFailure && index == 1 ? other : viewer,
                batchDeadline: deadline, callDeadline: deadline))
        } }
        if perPairFailure {
            await #expect(throws: RecoveryFixtureFailure.self) { try await tasks[0].value }
            #expect(try await tasks[1].value == state)
        } else {
            // One dictionary entry fans out to five real replies. Charging only
            // the unique pair would incorrectly pass the same 1KiB budget.
            for task in tasks {
                await #expect(throws: V2HostRoomRecoveryBatchError.oversized) { try await task.value }
            }
        }
    }

    @Test("shared retained items reserve a full trusted cohort and grant purposes FIFO")
    func sharedCollectorReservesCoverageAndDrainsActual() async throws {
        let owner = try V2RoomDataOwner(shardID: "room-a", epoch: 0)
        let host = V2ActorHostIdentity(hostID: try .init("fair-read-host"), incarnationID: UUID())
        let deadline = ContinuousClock.now + .seconds(20)
        let turn: @Sendable (UserID) -> V2GrantedRoomReadTurn = { viewer in
            .init(token: .init(roomID: .init(uuid: UUID()), owner: owner, activationEpoch: try! .init(1), host: host),
                actorUserID: viewer, batchDeadline: .now, callDeadline: deadline)
        }
        let gate = OrderedRecoveryGate()
        defer { Task { await gate.releaseAll() } }
        let batcher = V2HostRoomRecoveryQueryBatcher(configuration: try .init(
            maximumItems: 2, maximumPendingItems: 8, maximumInFlightBatches: 1),
            executeStates: { turns in
                await gate.enter(turns.map(\.actorUserID))
                throw V2RoomCallFailure.outcomeUnknown
            }, execute: { _, _ in throw V2HostRoomRecoveryBatchError.corruptResult })
        let initialViewer = UserID(uuid: UUID())
        let held = Task { try await batcher.state(turn(initialViewer)) }
        try await observe { await gate.entries().count == 1 }
        var peers: [Task<V2RoomStateReadResult, any Error>] = []
        let viewers = (0..<5).map { _ in UserID(uuid: UUID()) }
        for (index, viewer) in viewers.enumerated() {
            peers.append(Task { try await batcher.state(turn(viewer)) })
            try await observe { await batcher.pendingCount == index + 1 }
        }
        let coverageViewers = (0..<2).map { _ in UserID(uuid: UUID()) }
        let coverage = Task { try await batcher.states(coverageViewers.map(turn)) }
        try await observe { await batcher.pendingCount == 7 }
        let full = await batcher.collectorSnapshot()
        #expect(full.retainedItems == 8 && full.ordinaryRetainedItems == 6 && full.actualBatches == 1)
        let exportedFull = batcher.pressureSnapshot()
        #expect(exportedFull.retainedItems == 8 && exportedFull.pendingItems == 7 && exportedFull.actualBatches == 1)
        #expect(exportedFull.retainedBytes == full.retainedBytes && exportedFull.itemsSelected == 1)
        await #expect(throws: V2HostRoomRecoveryBatchError.busy) {
            _ = try await batcher.state(turn(.init(uuid: UUID())))
        }
        peers[4].cancel()
        await #expect(throws: CancellationError.self) { try await peers[4].value }
        #expect(await batcher.collectorSnapshot().retainedItems == 7)
        await gate.releaseNext()
        await #expect(throws: V2RoomCallFailure.outcomeUnknown) { try await held.value }
        try await observe { await gate.entries().count == 2 }
        #expect(await gate.entries()[1] == coverageViewers)
        await gate.releaseNext()
        await #expect(throws: V2RoomCallFailure.outcomeUnknown) { try await coverage.value }
        try await observe { await gate.entries().count == 3 }
        #expect(await gate.entries()[2] == Array(viewers.prefix(2)))
        let stopped = Task { await batcher.shutdown() }
        try await observe { await batcher.pendingCount == 0 }
        let draining = await batcher.collectorSnapshot()
        #expect(draining.actualBatches == 1 && draining.retainedItems == 2)
        await gate.releaseAll()
        await stopped.value
        for peer in peers.prefix(4) { _ = await peer.result }
        let done = await batcher.collectorSnapshot()
        #expect(done.actualBatches == 0 && done.retainedItems == 0 && done.retainedBytes == 0)
        #expect(await batcher.scheduledKeyCount == 0)
    }

    @Test("streamed committed pages release their own pin while remaining SQL owns the batch slot")
    func streamedPullSettlementAndUnknownDrain() async throws {
        let owner = try V2RoomDataOwner(shardID: "room-a", epoch: 0)
        let token = V2RoomActivationToken(roomID: .init(uuid: UUID()), owner: owner,
            activationEpoch: try .init(1), host: .init(hostID: try .init("stream-host"), incarnationID: UUID()))
        let viewer = UserID(uuid: UUID()), deadline = ContinuousClock.now + .seconds(10)
        let entered = RecoveryExecutionGate(), firstRelease = RecoveryExecutionGate()
        let partialEntered = RecoveryExecutionGate(), partialRelease = RecoveryExecutionGate(), finalRelease = RecoveryExecutionGate()
        defer { Task { await firstRelease.signal(); await partialRelease.signal(); await finalRelease.signal() } }
        let invocations = Mutex(0)
        let batcher = V2HostRoomRecoveryQueryBatcher(configuration: try .init(
            maximumItems: 2, maximumPendingItems: 6, maximumInFlightBatches: 1),
            executeStates: { _ in throw V2HostRoomRecoveryBatchError.corruptResult },
            executePulls: { items, _, settled in
                let index = invocations.withLock { value in defer { value += 1 }; return value }
                if index == 0 {
                    #expect(items.count == 1)
                    await entered.signal(); await firstRelease.wait()
                    await settled(items[0].id, .failure(V2RoomCallFailure.outcomeUnknown))
                } else {
                    #expect(items.count == 2)
                    await partialEntered.signal(); await partialRelease.wait()
                    let page = try V2ActorRoomLogPageWire(roomID: token.roomID, events: [], nextRoomSequence: 0,
                        hasMore: false, logTrimmedThroughRoomSequence: 0)
                    await settled(items[0].id, .success(.page(page)))
                    await finalRelease.wait()
                    await settled(items[1].id, .failure(V2RoomCallFailure.outcomeUnknown))
                }
            }, execute: { _, _ in throw V2HostRoomRecoveryBatchError.corruptResult })
        func grant(_ after: UInt64) throws -> V2GrantedRoomLogPull {
            .init(token: token, query: try .init(roomID: token.roomID, actorUserID: viewer,
                afterRoomSequence: after, pageSize: 100), callDeadline: deadline)
        }
        let firstGrant = try grant(0), secondGrant = try grant(0), thirdGrant = try grant(1)
        let first = Task { try await batcher.pull(firstGrant) }
        await entered.wait()
        let second = Task { try await batcher.pull(secondGrant) }
        try await observe { await batcher.pendingCount == 1 }
        let third = Task { try await batcher.pull(thirdGrant) }
        try await observe { await batcher.pendingCount == 2 }
        first.cancel()
        #expect(await batcher.collectorSnapshot().retainedItems == 3)
        await firstRelease.signal()
        await #expect(throws: V2RoomCallFailure.outcomeUnknown) { try await first.value }
        await partialEntered.wait()
        await partialRelease.signal()
        _ = try await second.value
        let partial = await batcher.collectorSnapshot()
        #expect(partial.retainedItems == 1 && partial.actualBatches == 1 && partial.itemsSettled == 2)
        let exportedPartial = batcher.pressureSnapshot()
        #expect(exportedPartial.retainedItems == 1 && exportedPartial.actualBatches == 1 && exportedPartial.itemsSettled == 2)
        third.cancel()
        let stopped = Task { await batcher.shutdown() }
        #expect(await batcher.collectorSnapshot().actualBatches == 1)
        await finalRelease.signal()
        await #expect(throws: V2RoomCallFailure.outcomeUnknown) { try await third.value }
        await stopped.value
        #expect(await batcher.collectorSnapshot().retainedItems == 0)
        #expect(await batcher.collectorSnapshot().actualBatches == 0)
    }

    private func observe(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(await condition())
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

private actor RecoveryExecutionGate {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        signalled = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private struct RecoveryFixtureFailure: Error { let detail: String }

private actor OrderedRecoveryGate {
    private var values: [[UserID]] = []
    private var held: [CheckedContinuation<Void, Never>] = []
    private var open = false
    func enter(_ viewers: [UserID]) async {
        values.append(viewers)
        if !open { await withCheckedContinuation { held.append($0) } }
    }
    func entries() -> [[UserID]] { values }
    func releaseNext() { if !held.isEmpty { held.removeFirst().resume() } }
    func releaseAll() { open = true; let all = held; held.removeAll(); for item in all { item.resume() } }
}
