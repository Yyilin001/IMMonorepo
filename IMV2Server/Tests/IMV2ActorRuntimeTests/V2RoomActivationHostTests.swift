import Foundation
import IMV2ActorContracts
import IMV2Core
import Testing
@testable import IMV2ActorRuntime

@Suite("Room activation host owns restore, lease and retirement")
struct V2RoomActivationHostTests {
    @Test("shared restore survives one cancelled waiter and renews before ready")
    func sharedRestore() async throws {
        let gate = Gate()
        let fixture = try Fixture(restoreGate: gate)
        await fixture.host.start()
        let first = fixture.activate()
        try await gate.waitForEntries(1)
        let second = fixture.activate()
        try await waitUntil { await fixture.host.snapshot().activationWaiters == 2 }
        #expect(await fixture.host.snapshot().activeRooms == 0)
        first.cancel()
        await expectFailure(.notAccepted(.cancelled), first)
        try await waitUntil { await fixture.store.renewCount > 0 }
        #expect(await fixture.host.snapshot().activeRooms == 0)
        await gate.open()
        let result = try await second.value
        guard case .ready(let token) = result else { Issue.record("expected ready"); return }
        #expect(token.roomID == fixture.room)
        #expect(await fixture.store.acquireCount == 1)
        #expect(await fixture.host.snapshot().activeRooms == 1)
        let drained = await fixture.host.drain(deadline: .now + .seconds(2))
        #expect(drained.completed)
    }

    @Test("one timed-out waiter is removed without cancelling the shared restore")
    func waiterDeadline() async throws {
        let gate = Gate()
        let fixture = try Fixture(restoreGate: gate)
        await fixture.host.start()
        let short = fixture.activate(deadline: .now + .milliseconds(50))
        try await gate.waitForEntries(1)
        let remaining = fixture.activate()
        await expectFailure(.notAccepted(.deadlineExceeded), short)
        #expect(await fixture.host.snapshot().activationWaiters == 1)
        await gate.open()
        guard case .ready = try await remaining.value else {
            Issue.record("expected shared restore to become ready"); return
        }
        #expect(await fixture.store.acquireCount == 1)
        #expect((await fixture.host.drain(deadline: .now + .seconds(2))).completed)
    }

    @Test("pending and per-room waiter limits reject without creating extra work")
    func boundedActivation() async throws {
        let gate = Gate()
        let fixture = try Fixture(maximumActiveRooms: 1, waiters: 1, restoreGate: gate)
        await fixture.host.start()
        let first = fixture.activate()
        try await gate.waitForEntries(1)
        await expectFailure(.notAccepted(.overloaded), fixture.activate())
        let other = RoomID(uuid: UUID())
        await expectFailure(.notAccepted(.overloaded), fixture.activate(roomID: other))
        #expect(await fixture.store.acquireCount == 1)
        #expect(await fixture.host.snapshot().pendingRooms == 1)
        await gate.open()
        _ = try await first.value
        #expect(await fixture.host.snapshot().pendingRooms == 0)
        #expect((await fixture.host.drain(deadline: .now + .seconds(2))).completed)
    }

    @Test("restore concurrency bound queues another room without starting its acquire")
    func boundedRestores() async throws {
        let gate = Gate()
        let fixture = try Fixture(restoreGate: gate)
        await fixture.host.start()
        let first = fixture.activate()
        try await gate.waitForEntries(1)
        let secondRoom = RoomID(uuid: UUID())
        let second = fixture.activate(roomID: secondRoom)
        try await waitUntil { await fixture.host.snapshot().pendingRooms == 2 }
        #expect(await fixture.store.acquireCount == 1)
        await gate.open()
        guard case .ready = try await first.value, case .ready = try await second.value else {
            Issue.record("expected both rooms ready"); return
        }
        #expect(await fixture.store.acquireCount == 2)
        #expect((await fixture.host.drain(deadline: .now + .seconds(2))).completed)
    }

    @Test("unknown room fails through lease authority and never creates an executor")
    func unknownRoom() async throws {
        let fixture = try Fixture(missingRoom: true)
        await fixture.host.start()
        await expectFailure(.notAccepted(.notFound), fixture.activate())
        #expect(await fixture.store.acquireCount == 1)
        #expect(await fixture.probe.restoreCount == 0)
        #expect(await fixture.host.snapshot().pendingRooms == 0)
    }

    @Test("another host's lease redirects without local restore")
    func occupiedRoom() async throws {
        let fixture = try Fixture(occupiedByOther: true)
        await fixture.host.start()
        guard case .occupied(let lease) = try await fixture.activate().value else {
            Issue.record("expected occupied"); return
        }
        #expect(lease.token.roomID == fixture.room)
        #expect(await fixture.probe.restoreCount == 0)
        #expect(await fixture.host.snapshot().activeRooms == 0)
    }

    @Test("unknown acquire commit never publishes or releases an unreturned lease")
    func unknownAcquire() async throws {
        let fixture = try Fixture(unknownAcquire: true)
        await fixture.host.start()
        await expectFailure(.outcomeUnknown, fixture.activate())
        #expect(await fixture.host.readyTokens().isEmpty)
        #expect(await fixture.probe.restoreCount == 0)
        #expect(await fixture.store.releaseCount == 0)
        guard case .occupied(let lease) = try await fixture.activate().value else {
            Issue.record("the possibly committed self lease must remain occupied"); return
        }
        #expect(lease.token.roomID == fixture.room)
        #expect(await fixture.host.readyTokens().isEmpty)
        #expect(await fixture.probe.restoreCount == 0)
        #expect((await fixture.host.drain(deadline: .now + .seconds(2))).completed)
    }

    @Test("restore failure closes executor and conditionally releases its token")
    func restoreFailure() async throws {
        let fixture = try Fixture(failRestore: true)
        await fixture.host.start()
        await expectFailure(.notAccepted(.unavailable), fixture.activate())
        try await waitUntil { await fixture.store.releaseCount == 1 }
        #expect(await fixture.probe.closeCount == 1)
        #expect(await fixture.host.snapshot().activeRooms == 0)
        #expect(await fixture.host.snapshot().pendingRooms == 0)
    }

    @Test("restore deadline removes waiters but never releases a still-running restore")
    func restoreTimeout() async throws {
        let gate = Gate()
        let fixture = try Fixture(shortLease: true, restoreGate: gate)
        await fixture.host.start()
        let activation = fixture.activate()
        try await gate.waitForEntries(1)
        await expectFailure(.notAccepted(.leaseLost), activation)
        #expect(await fixture.store.releaseCount == 0)
        #expect(await fixture.probe.closeCount == 0)
        await gate.open()
        try await waitUntil { await fixture.store.releaseCount == 1 }
        #expect(await fixture.probe.closeCount == 1)
    }

    @Test("watchdog retires expired lease and a delayed renew cannot revive it")
    func safetyExpiry() async throws {
        let gate = Gate()
        let fixture = try Fixture(shortLease: true, renewGate: gate)
        await fixture.host.start()
        guard case .ready(let token) = try await fixture.activate().value else {
            Issue.record("expected ready"); return
        }
        try await gate.waitForEntries(1)
        try await waitUntil { await fixture.store.releaseCount == 1 }
        await expectFailure(.notAccepted(.staleActivation), fixture.invoke(token: token))
        await gate.open()
        try await Task.sleep(for: .milliseconds(30))
        #expect(await fixture.host.snapshot().activeRooms == 0)
    }

    @Test("drain blocks new admission but leaves an executing transaction alive")
    func drainWithExecutingTurn() async throws {
        let gate = Gate()
        let fixture = try Fixture(executeGate: gate)
        await fixture.host.start()
        guard case .ready(let token) = try await fixture.activate().value else {
            Issue.record("expected ready"); return
        }
        let executing = fixture.invoke(token: token)
        try await gate.waitForEntries(1)
        let firstDrain = await fixture.host.drain(deadline: .now + .milliseconds(40))
        #expect(!firstDrain.completed)
        #expect(await fixture.probe.closeCount == 0)
        await expectFailure(.notAccepted(.staleActivation), fixture.invoke(token: token))
        await gate.open()
        #expect(try await executing.value == 1)
        #expect((await fixture.host.drain(deadline: .now + .seconds(2))).completed)
        #expect(await fixture.probe.closeCount == 1)
        #expect(await fixture.store.releaseCount == 1)
    }

    @Test("unknown completion fences before dropping unresolved capacity")
    func uncertainTurn() async throws {
        let fixture = try Fixture(unknownCompletion: true)
        await fixture.host.start()
        guard case .ready(let token) = try await fixture.activate().value else {
            Issue.record("expected ready"); return
        }
        await expectFailure(.outcomeUnknown, fixture.invoke(token: token))
        try await waitUntil { await fixture.store.releaseCount == 1 }
        #expect(await fixture.probe.closeCount == 1)
        try await waitUntil { await fixture.budget.snapshot().commandCount == 0 }
    }

    @Test("reservation completion invalidates once while barrier is held")
    func reservationCompletion() async throws {
        let fixture = try Fixture()
        await fixture.host.start()
        guard case .ready(let token) = try await fixture.activate().value else {
            Issue.record("expected ready"); return
        }
        let grant = try await fixture.host.reserve(
            token: token, requestID: UUID(), deadline: .now + .seconds(1)
        )
        try await fixture.host.markReservationDispatched(grant)
        #expect(await fixture.host.finishReservation(grant, completion: .committed))
        #expect(!(await fixture.host.finishReservation(grant, completion: .committed)))
        #expect(await fixture.probe.invalidations == 1)
        #expect((await fixture.host.drain(deadline: .now + .seconds(2))).completed)
    }

    @Test("concurrent duplicate finish cannot invalidate twice")
    func concurrentFinish() async throws {
        let gate = Gate()
        let fixture = try Fixture(invalidationGate: gate)
        await fixture.host.start()
        guard case .ready(let token) = try await fixture.activate().value else {
            Issue.record("expected ready"); return
        }
        let grant = try await fixture.host.reserve(token: token, requestID: UUID(),
                                                   deadline: .now + .seconds(1))
        try await fixture.host.markReservationDispatched(grant)
        let first = Task { await fixture.host.finishReservation(grant, completion: .committed) }
        try await gate.waitForEntries(1)
        #expect(!(await fixture.host.finishReservation(grant, completion: .committed)))
        first.cancel()
        await gate.open()
        #expect(await first.value)
        #expect(await fixture.probe.invalidations == 1)
        #expect((await fixture.host.drain(deadline: .now + .seconds(2))).completed)
    }

    @Test("an accepted reservation may dispatch and finish during drain")
    func reservationDuringDrain() async throws {
        let fixture = try Fixture()
        await fixture.host.start()
        guard case .ready(let token) = try await fixture.activate().value else {
            Issue.record("expected ready"); return
        }
        let grant = try await fixture.host.reserve(token: token, requestID: UUID(),
                                                   deadline: .now + .seconds(1))
        await fixture.host.beginDrain()
        try await fixture.host.markReservationDispatched(grant)
        #expect(await fixture.host.finishReservation(grant, completion: .committed))
        #expect((await fixture.host.drain(deadline: .now + .seconds(2))).completed)
    }

    @Test("release error keeps the room tracked and retries after executor close")
    func releaseRetry() async throws {
        let fixture = try Fixture(releaseFailures: 1)
        await fixture.host.start()
        _ = try await fixture.activate().value
        let drained = await fixture.host.drain(deadline: .now + .seconds(2))
        #expect(drained.completed)
        #expect(await fixture.store.releaseCount >= 2)
        #expect(await fixture.probe.closeCount == 1)
    }

    @Test("acquire returning after drain never publishes a ready activation")
    func lateAcquireAfterDrain() async throws {
        let gate = Gate()
        let fixture = try Fixture(acquireGate: gate)
        await fixture.host.start()
        let activation = fixture.activate()
        try await gate.waitForEntries(1)
        let first = await fixture.host.drain(deadline: .now + .milliseconds(30))
        #expect(!first.completed)
        await expectFailure(.notAccepted(.retired), activation)
        await gate.open()
        #expect((await fixture.host.drain(deadline: .now + .seconds(2))).completed)
        #expect(await fixture.store.releaseCount == 1)
        #expect(await fixture.host.readyTokens().isEmpty)
    }

    @Test("idle passivation closes admission and permits a new epoch")
    func idlePassivation() async throws {
        let fixture = try Fixture(idleMilliseconds: 60)
        await fixture.host.start()
        guard case .ready(let first) = try await fixture.activate().value else {
            Issue.record("expected ready"); return
        }
        try await waitUntil { await fixture.store.releaseCount == 1 }
        #expect(await fixture.host.readyTokens().isEmpty)
        guard case .ready(let second) = try await fixture.activate().value else {
            Issue.record("expected second ready"); return
        }
        #expect(second.activationEpoch > first.activationEpoch)
        #expect((await fixture.host.drain(deadline: .now + .seconds(2))).completed)
    }

    @Test("coalesced lifecycle changes reconcile exact ready tokens")
    func lifecycleChanges() async throws {
        let fixture = try Fixture()
        await fixture.host.start()
        let stream = await fixture.host.changes()
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == 0)
        guard case .ready(let token) = try await fixture.activate().value else {
            Issue.record("expected ready"); return
        }
        #expect(await iterator.next() == 1)
        #expect(await fixture.host.readyTokens() == [token])
        await fixture.host.beginDrain()
        #expect(await iterator.next() == 2)
        #expect(await fixture.host.readyTokens().isEmpty)
        #expect((await fixture.host.drain(deadline: .now + .seconds(2))).completed)
    }

    private func expectFailure<T: Sendable>(_ expected: V2RoomCallFailure,
                                             _ task: Task<T, any Error>) async {
        do { _ = try await task.value; Issue.record("unexpected success") }
        catch { #expect(error as? V2RoomCallFailure == expected) }
    }

    private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw TestFailure.timeout }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private enum TestFailure: Error { case timeout, restore }

    private struct Command: Codable, Sendable { let value: Int }

    private struct Fixture {
        let room = RoomID(uuid: UUID())
        let owner: V2RoomDataOwner
        let store: FakeLeaseStore
        let probe: Probe
        let budget: V2RoomCommandBudget
        let host: V2RoomActivationHost<Command, Int>

        init(maximumActiveRooms: Int = 2, waiters: Int = 3, shortLease: Bool = false,
             restoreGate: Gate? = nil, executeGate: Gate? = nil,
             renewGate: Gate? = nil, acquireGate: Gate? = nil,
             invalidationGate: Gate? = nil, releaseFailures: Int = 0,
             idleMilliseconds: Int64 = 2_000, failRestore: Bool = false,
             unknownCompletion: Bool = false, missingRoom: Bool = false,
             occupiedByOther: Bool = false, unknownAcquire: Bool = false) throws {
            owner = try .init(shardID: "test", epoch: 0)
            let config = try V2RoomRuntimeConfiguration(
                maximumActiveRooms: maximumActiveRooms, maximumConcurrentRestores: 1,
                maximumActivationWaitersPerRoom: waiters,
                maximumPendingActivations: maximumActiveRooms,
                maximumActivationWaitersPerHost: waiters,
                maximumConcurrentResolutions: 1, maximumConcurrentReservations: 1,
                leaseDurationMilliseconds: shortLease ? 200 : 1_000,
                renewalIntervalMilliseconds: shortLease ? 20 : 100,
                renewalSafetyMarginMilliseconds: shortLease ? 50 : 100,
                transactionTimeoutMilliseconds: shortLease ? 50 : 100,
                callTimeoutMilliseconds: shortLease ? 100 : 500,
                batchWaitMilliseconds: 1, idleTimeoutMilliseconds: idleMilliseconds,
                drainTimeoutMilliseconds: shortLease ? 150 : 600,
                reservationTimeoutMilliseconds: shortLease ? 80 : 200
            )
            let identity = V2ActorHostIdentity(hostID: V2ActorHostID(uuid: UUID()), incarnationID: UUID())
            store = FakeLeaseStore(renewGate: renewGate, acquireGate: acquireGate,
                                   releaseFailures: releaseFailures, missingRoom: missingRoom,
                                   occupiedByOther: occupiedByOther, unknownAcquire: unknownAcquire)
            probe = Probe(restoreGate: restoreGate, executeGate: executeGate,
                          invalidationGate: invalidationGate,
                          failRestore: failRestore, unknownCompletion: unknownCompletion)
            budget = V2RoomCommandBudget(configuration: config)
            let probe = probe
            host = .init(
                identity: identity, leaseStore: store, configuration: config, budget: budget,
                classify: { _ in .barrier },
                factory: .init { _ in
                    .init(restore: { _ in try await probe.restore() },
                          execute: { await probe.execute($0) },
                          invalidateReservation: { _ in await probe.invalidate() },
                          close: { await probe.close() })
                }
            )
        }

        func activate(roomID: RoomID? = nil,
                      deadline: ContinuousClock.Instant = .now + .seconds(2))
            -> Task<V2RoomActivationResolution, any Error> {
            let roomID = roomID ?? room
            return Task { try await host.activate(roomID: roomID, owner: owner, deadline: deadline) }
        }

        func invoke(token: V2RoomActivationToken) -> Task<Int, any Error> {
            Task {
                try await host.invoke(token: token, encodedRequest: JSONEncoder().encode(Command(value: 1)),
                                      deadline: .now + .seconds(2))
            }
        }
    }

    private actor FakeLeaseStore: V2RoomActivationLeaseStore {
        private var current: [RoomID: V2RoomActivationLease] = [:]
        private var epoch: Int64 = 0
        private let renewGate: Gate?
        private let acquireGate: Gate?
        private var releaseFailures: Int
        private let missingRoom: Bool
        private let occupiedByOther: Bool
        private var unknownAcquire: Bool
        var acquireCount = 0
        var renewCount = 0
        var releaseCount = 0

        init(renewGate: Gate?, acquireGate: Gate?, releaseFailures: Int,
             missingRoom: Bool, occupiedByOther: Bool, unknownAcquire: Bool) {
            self.renewGate = renewGate
            self.acquireGate = acquireGate
            self.releaseFailures = releaseFailures
            self.missingRoom = missingRoom
            self.occupiedByOther = occupiedByOther
            self.unknownAcquire = unknownAcquire
        }

        func locate(roomID: RoomID, owner: V2RoomDataOwner) async throws -> V2RoomActivationLease? {
            current[roomID]
        }

        func acquire(roomID: RoomID, owner: V2RoomDataOwner,
                     host: V2ActorHostIdentity, duration: V2ActorMilliseconds) async throws -> V2RoomActivationAcquisition {
            acquireCount += 1
            if let acquireGate { await acquireGate.wait() }
            if missingRoom { throw V2RoomActivationLeaseError.roomNotFound }
            if let lease = current[roomID] { return .occupied(lease) }
            epoch += 1
            let grantHost = occupiedByOther
                ? V2ActorHostIdentity(hostID: V2ActorHostID(uuid: UUID()), incarnationID: UUID())
                : host
            let token = V2RoomActivationToken(roomID: roomID, owner: owner,
                                               activationEpoch: try .init(epoch), host: grantHost)
            let lease = try makeLease(token, duration: duration)
            current[roomID] = lease
            if unknownAcquire {
                unknownAcquire = false
                throw V2RoomActivationLeaseError.outcomeUnknown
            }
            if occupiedByOther { return .occupied(lease) }
            return .acquired(lease)
        }

        func renew(token: V2RoomActivationToken,
                   duration: V2ActorMilliseconds) async throws -> V2RoomActivationLease {
            renewCount += 1
            if let renewGate { await renewGate.wait() }
            guard current[token.roomID]?.token == token else {
                throw V2RoomActivationLeaseError.activationChanged
            }
            let lease = try makeLease(token, duration: duration)
            current[token.roomID] = lease
            return lease
        }

        func release(token: V2RoomActivationToken) async throws -> Bool {
            releaseCount += 1
            if releaseFailures > 0 {
                releaseFailures -= 1
                throw V2RoomActivationLeaseError.activationChanged
            }
            guard current[token.roomID]?.token == token else { return false }
            current.removeValue(forKey: token.roomID)
            return true
        }

        private func makeLease(_ token: V2RoomActivationToken,
                               duration: V2ActorMilliseconds) throws -> V2RoomActivationLease {
            let observed = Date(timeIntervalSince1970: 1_000)
            return try .init(token: token, databaseObservedAt: observed,
                             expiresAt: observed.addingTimeInterval(Double(duration.rawValue) / 1_000))
        }
    }

    private actor Probe {
        private let restoreGate: Gate?
        private let executeGate: Gate?
        private let invalidationGate: Gate?
        private let failRestore: Bool
        private let unknownCompletion: Bool
        var closeCount = 0
        var invalidations = 0
        var restoreCount = 0

        init(restoreGate: Gate?, executeGate: Gate?, invalidationGate: Gate?,
             failRestore: Bool, unknownCompletion: Bool) {
            self.restoreGate = restoreGate
            self.executeGate = executeGate
            self.invalidationGate = invalidationGate
            self.failRestore = failRestore
            self.unknownCompletion = unknownCompletion
        }

        func restore() async throws {
            restoreCount += 1
            if let restoreGate { await restoreGate.wait() }
            if failRestore { throw TestFailure.restore }
        }

        func execute(_ turn: V2RoomTurn<Command>) async -> V2RoomTransactionCompletion<[Int]> {
            if let executeGate { await executeGate.wait() }
            if unknownCompletion { return .outcomeUnknown }
            return .committed(turn.items.map(\.request.value))
        }

        func invalidate() async {
            invalidations += 1
            if let invalidationGate { await invalidationGate.wait() }
        }
        func close() { closeCount += 1 }
    }

    private actor Gate {
        private var opened = false
        private var entries = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            entries += 1
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            opened = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }

        func waitForEntries(_ count: Int) async throws {
            let deadline = ContinuousClock.now + .seconds(2)
            while entries < count {
                guard ContinuousClock.now < deadline else { throw TestFailure.timeout }
                try await Task.sleep(for: .milliseconds(2))
            }
        }
    }
}
