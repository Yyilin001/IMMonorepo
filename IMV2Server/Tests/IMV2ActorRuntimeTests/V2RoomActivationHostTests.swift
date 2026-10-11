import Foundation
import Synchronization
import IMV2ActorContracts
import IMV2Core
import Testing
@testable import IMV2ActorRuntime

@Suite("Room activation host owns restore, lease and retirement")
struct V2RoomActivationHostTests {
    @Test("local host and execution handle never encode or decode ordinary requests")
    func ordinaryInvocationDecodesOnce() async throws {
        DecodeCountCommand.count.withLock { $0 = 0 }
        let configuration = try V2RoomRuntimeConfiguration(maximumRequestBytes: 128)
        let budget = V2RoomCommandBudget(configuration: configuration)
        let store = FakeLeaseStore(renewGate: nil, acquireGate: nil, releaseFailures: 0,
            missingRoom: false, occupiedByOther: false, unknownAcquire: false,
            renewFailures: [], repeatedRenewFailure: nil)
        let identity = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let host = V2RoomActivationHost<DecodeCountCommand, Int>(identity: identity,
            leaseStore: store, configuration: configuration, budget: budget,
            classify: { _ in .barrier }, factory: .init(pureRoomLogPull: { _, _, _ in
                Issue.record("ordinary request entered pure-read executor"); return .rolledBack(.invalidRequest)
            }) { _ in
                .init(restore: { _ in }, execute: { .committed($0.items.map { $0.request.value }) },
                      invalidateReservation: { _ in }, close: {})
            }, qualification: .standalone())
        await host.start()
        do {
            let room = RoomID(uuid: UUID()), owner = try V2RoomDataOwner(shardID: "decode-once", epoch: 0)
            guard case .ready(let token) = try await host.activate(roomID: room, owner: owner,
                deadline: .now + .seconds(2)) else { throw TestFailure.restore }
            let request = DecodeCountCommand(value: 31)
            #expect(try await host.invoke(token: token, request: request, deadline: .now + .seconds(2)) == 31)
            #expect(DecodeCountCommand.count.withLock { $0 } == 0)
            // Local callers retain and pass models without invoking Codable.
            let handle = try host.executionHandle(token: token)
            #expect(try await handle.invoke(request: request, deadline: .now + .seconds(2)) == 31)
            #expect(DecodeCountCommand.count.withLock { $0 } == 0)
            #expect(try await host.invoke(token: token, request: DecodeCountCommand(value: 32), deadline: .now + .seconds(2)) == 32)
            #expect(try await handle.invoke(request: DecodeCountCommand(value: 33), deadline: .now + .seconds(2)) == 33)
            #expect(DecodeCountCommand.count.withLock { $0 } == 0)
            await #expect(throws: V2RoomCallFailure.notAccepted(.invalidRequest)) {
                try await host.invoke(token: token, request: DecodeCountCommand(value: 1, padding: String(repeating: "x", count: 129)),
                                      deadline: .now + .seconds(2))
            }
            #expect(DecodeCountCommand.count.withLock { $0 } == 0)
            #expect(budget.snapshot().commandCount == 0)
            #expect((await host.stop(deadline: .now + .seconds(2))).completed)
        } catch {
            _ = await host.stop(deadline: .now + .seconds(2)); throw error
        }
    }

    private struct DecodeCountCommand: Codable, Sendable {
        static let count = Mutex(0)
        let value: Int
        let padding: String
        init(value: Int, padding: String = "") { self.value = value; self.padding = padding }
        init(from decoder: any Decoder) throws {
            padding = ""
            Self.count.withLock { $0 += 1 }
            value = try decoder.container(keyedBy: CodingKeys.self).decode(Int.self, forKey: .value)
        }
        private enum CodingKeys: String, CodingKey { case value }
    }

    @Test("ready calls execute while the shared lifecycle actor is held")
    func executionHandleBypassesHeldHost() async throws {
        let fixture = try Fixture()
        await fixture.host.start()
        guard case .ready(let token) = try await fixture.activate().value else { throw TestFailure.restore }
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let held = Task.detached { await fixture.host.holdLifecycleForTest(entered: entered, release: release) }
        let didEnter = await Task.detached { hostTestWaitForEntered(entered) }.value
            #expect(didEnter)
        do {
            #expect(try await fixture.host.invoke(token: token,
                request: Command(value: 1), deadline: .now + .milliseconds(200)) == 1)
            release.signal(); await held.value
            #expect((await fixture.host.drain(deadline: .now + .seconds(2))).completed)
        } catch {
            release.signal(); await held.value
            _ = await fixture.host.drain(deadline: .now + .seconds(2)); throw error
        }
    }

    @Test("a cached execution handle observes proof revocation before Host notification")
    func executionHandleSeesRevocationSynchronously() async throws {
        let qualification = try V2ActorServiceQualification(localNodeID: "a", roster: ["a", "b", "c"])
        _ = qualification.update(witnesses: ["b": .now + .seconds(5)])
        let fixture = try Fixture(qualification: qualification)
        await fixture.host.start()
        guard case .ready(let token) = try await fixture.activate().value else { throw TestFailure.restore }
        let handle = try fixture.host.executionHandle(token: token)
        qualification.revoke()
        await #expect(throws: V2RoomCallFailure.notAccepted(.leaseLost)) {
            try await handle.invoke(request: Command(value: 1), deadline: .now + .seconds(1))
        }
        await fixture.host.qualificationDidChange()
        #expect((await fixture.host.drain(deadline: .now + .seconds(2))).completed)
    }

    @Test("last queued waiter disposes an unstarted activation while actual restore stays owned", arguments: [false, true])
    func queuedActivationDisposesLastWaiter(expires: Bool) async throws {
        let gate = Gate()
        let fixture = try Fixture(restoreGate: gate)
        await fixture.host.start()
        let active = fixture.activate()
        try await gate.waitForEntries(1)
        let room = RoomID(uuid: UUID())
        let queued = fixture.activate(roomID: room,
            deadline: .now + (expires ? .milliseconds(80) : .seconds(2)))
        try await waitUntil { await fixture.host.snapshot().activationWaiters == 2 }
        if !expires { queued.cancel() }
        await expectFailure(.notAccepted(expires ? .deadlineExceeded : .cancelled), queued)
        #expect(await fixture.host.snapshot().pendingRooms == 1)
        #expect(await fixture.host.snapshot().restoringRooms == 1)
        #expect(await fixture.store.acquireCount == 1)
        let successor = fixture.activate(roomID: room)
        try await waitUntil { await fixture.host.snapshot().activationWaiters == 2 }
        await gate.open()
        guard case .ready = try await active.value, case .ready = try await successor.value else {
            Issue.record("actual and successor activation must become ready"); return
        }
        #expect(await fixture.store.acquireCount == 2)
        #expect(await fixture.host.snapshot().pendingRooms == 0)
        #expect((await fixture.host.drain(deadline: .now + .seconds(2))).completed)
    }

    @Test("qualification revocation owns late lease SQL and a new proof cannot revive its old entry", arguments: [false, true])
    func qualificationFencesLateLeaseSQL(renewal: Bool) async throws {
        let qualification = try V2ActorServiceQualification(localNodeID: "a", roster: ["a", "b", "c"])
        let firstProof = try #require(qualification.update(witnesses: ["b": .now + .seconds(5)]))
        let gate = Gate()
        let fixture = try Fixture(renewGate: renewal ? gate : nil, acquireGate: renewal ? nil : gate,
            qualification: qualification)
        await fixture.host.start()
        let activation = fixture.activate()
        var oldToken: V2RoomActivationToken?
        do {
            if renewal {
                guard case .ready(let token) = try await activation.value else {
                    Issue.record("expected qualified activation"); throw TestFailure.restore
                }
                oldToken = token
            }
            try await gate.waitForEntries(1)
            qualification.revoke()
            await fixture.host.qualificationDidChange()
            #expect(!(await fixture.host.snapshot().accepting))
            #expect(await fixture.store.releaseCount == 0)
            if !renewal { await expectFailure(.notAccepted(.leaseLost), activation) }
            if let token = oldToken { #expect(!(await fixture.host.isReady(token: token))) }
            let replacement = try #require(qualification.update(witnesses: ["b": .now + .seconds(5)]))
            #expect(replacement.generation != firstProof.generation)
            await fixture.host.qualificationDidChange()
            // The shared SQL still owns the old entry even after eligibility returns.
            await expectFailure(.notAccepted(.leaseLost), fixture.activate())
            await gate.open()
            try await waitUntil { await fixture.host.snapshot().retiringRooms == 0 }
            #expect(await fixture.store.releaseCount == 1)
            guard case .ready(let token) = try await fixture.activate().value else {
                Issue.record("expected a fresh qualified entry"); throw TestFailure.restore
            }
            if let oldToken { #expect(token.activationEpoch > oldToken.activationEpoch) }
            #expect(await fixture.store.acquireCount == 2)
            // Operator stop is terminal even if the shared eligibility proof is refreshed.
            await fixture.host.beginDrain()
            qualification.revoke()
            _ = qualification.update(witnesses: ["b": .now + .seconds(5)])
            await fixture.host.qualificationDidChange()
            await expectFailure(.notAccepted(.retired), fixture.activate(roomID: RoomID(uuid: UUID())))
            #expect((await fixture.host.drain(deadline: .now + .seconds(2))).completed)
        } catch {
            await gate.open()
            _ = await fixture.host.drain(deadline: .now + .seconds(2))
            throw error
        }
    }

    @Test("qualification deadline stops service without depending on membership callbacks")
    func qualificationWatchdogExpires() async throws {
        let qualification = try V2ActorServiceQualification(localNodeID: "a", roster: ["a", "b", "c"])
        _ = qualification.update(witnesses: ["b": .now + .milliseconds(150)])
        let fixture = try Fixture(qualification: qualification)
        await fixture.host.start()
        guard case .ready(let token) = try await fixture.activate().value else {
            Issue.record("expected initially qualified activation")
            _ = await fixture.host.drain(deadline: .now + .seconds(2)); return
        }
        do { try await waitUntil { await fixture.store.releaseCount == 1 } }
        catch { _ = await fixture.host.drain(deadline: .now + .seconds(2)); throw error }
        #expect(!(await fixture.host.isReady(token: token)))
        #expect(!(await fixture.host.snapshot().accepting))
        #expect(await fixture.host.readyTokens().isEmpty)
        #expect((await fixture.host.drain(deadline: .now + .seconds(2))).completed)
    }

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
        try await waitUntil { await fixture.host.snapshot().retiringRooms == 1 }
        #expect(!(await fixture.host.isReady(token: token)))
        #expect(await fixture.store.releaseCount == 0)
        await expectFailure(.notAccepted(.retired), fixture.invoke(token: token))
        await gate.open()
        try await waitUntil { await fixture.store.releaseCount == 1 }
        #expect(await fixture.host.snapshot().activeRooms == 0)
    }

    @Test("confirmed deferred renewal can recover without retiring a safe activation")
    func deferredRenewalThenSuccess() async throws {
        let fixture = try Fixture(shortLease: true, renewFailures: [.renewalDeferred])
        let startedAt = ContinuousClock.now
        await fixture.host.start()
        guard case .ready(let token) = try await fixture.activate().value else {
            Issue.record("expected ready"); return
        }
        try await waitUntil { await fixture.store.successfulRenewCount > 0 }
        #expect(await fixture.store.renewCount >= 2)
        #expect(await fixture.store.releaseCount == 0)
        #expect(await fixture.host.isReady(token: token))
        // Cross the original 150ms safety window. Only an actual successful
        // renewal may keep readiness beyond that initial watchdog deadline.
        try await ContinuousClock().sleep(until: startedAt + .milliseconds(250))
        #expect(await fixture.host.isReady(token: token))
        #expect(await fixture.store.releaseCount == 0)
        #expect((await fixture.host.drain(deadline: .now + .seconds(2))).completed)
    }

    @Test("consecutive deferred renewals never move the original safety deadline")
    func deferredRenewalsExpireAtOriginalWatchdog() async throws {
        let fixture = try Fixture(shortLease: true, repeatedRenewFailure: .renewalDeferred)
        let startedAt = ContinuousClock.now
        await fixture.host.start()
        guard case .ready(let token) = try await fixture.activate().value else {
            Issue.record("expected ready"); return
        }
        try await waitUntil { await fixture.store.renewCount >= 2 }
        #expect(await fixture.host.isReady(token: token))
        try await ContinuousClock().sleep(until: startedAt + .milliseconds(250))
        #expect(!(await fixture.host.isReady(token: token)))
        try await waitUntil { await fixture.store.releaseCount == 1 }
        #expect(await fixture.store.successfulRenewCount == 0)
        #expect(await fixture.probe.closeCount == 1)
        await expectFailure(.notAccepted(.staleActivation), fixture.invoke(token: token))
        #expect((await fixture.host.drain(deadline: .now + .seconds(2))).completed)
    }

    @Test("unknown renewal outcome retires immediately without deferred retry")
    func unknownRenewalDoesNotDeferRetirement() async throws {
        let fixture = try Fixture(renewFailures: [.outcomeUnknown])
        let retirementBudget = ContinuousClock.now + .milliseconds(500)
        await fixture.host.start()
        guard case .ready(let token) = try await fixture.activate().value else {
            Issue.record("expected ready"); return
        }
        try await waitUntil(deadline: retirementBudget) { await fixture.store.releaseCount == 1 }
        #expect(await fixture.store.renewCount == 1)
        #expect(await fixture.store.successfulRenewCount == 0)
        #expect(!(await fixture.host.isReady(token: token)))
        #expect(await fixture.probe.closeCount == 1)
        #expect((await fixture.host.drain(deadline: .now + .seconds(2))).completed)
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
        try await waitUntil { fixture.budget.snapshot().commandCount == 0 }
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

    @Test("an old completed lane cannot clear its already admitted successor reservation")
    func reservationFinishPreservesSuccessor() async throws {
        let fixture = try Fixture()
        let gate = Gate()
        await fixture.host.start()
        guard case .ready(let token) = try await fixture.activate().value else {
            Issue.record("expected ready"); return
        }
        let first = try await fixture.host.reserve(token: token, requestID: UUID(), deadline: .now + .seconds(1))
        try await fixture.host.markReservationDispatched(first)
        await fixture.host.observeReservationFinish { grant in
            if grant == first { await gate.wait() }
        }
        let finish = Task { await fixture.host.finishReservation(first, completion: .committed) }
        do {
            try await gate.waitForEntries(1)
            // This gate is after the actual old permit release. A fresh real
            // reserve/dispatch completes while the old Host continuation waits.
            #expect(fixture.budget.snapshot().reservationCount == 0)
            let successor = try await fixture.host.reserve(token: token, requestID: UUID(),
                deadline: .now + .seconds(1))
            try await fixture.host.markReservationDispatched(successor)
            #expect(fixture.budget.snapshot().reservationCount == 1)
            // A different old finishing owner must not force the current
            // caller to retry settlement after its actual SQL completed.
            #expect(await fixture.host.finishReservation(successor, completion: .committed))
            #expect(!(await fixture.host.finishReservation(successor, completion: .committed)))
            #expect(fixture.budget.snapshot().reservationCount == 0)
            let third = try await fixture.host.reserve(token: token, requestID: UUID(),
                deadline: .now + .seconds(1))
            try await fixture.host.markReservationDispatched(third)
            await gate.open()
            #expect(await finish.value)
            // Neither the old held cleanup nor its finishing-owner defer may
            // clear the real third capability admitted before it resumed.
            #expect(fixture.budget.snapshot().reservationCount == 1)
            #expect(await fixture.host.finishReservation(third, completion: .committed))
            #expect(fixture.budget.snapshot().reservationCount == 0)
            #expect(await fixture.probe.invalidations == 3)
            #expect((await fixture.host.stop(deadline: .now + .seconds(2))).completed)
        } catch {
            await gate.open(); _ = await finish.value
            _ = await fixture.host.stop(deadline: .now + .seconds(2)); throw error
        }
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
        #expect(!(await fixture.host.isReady(token: first)))
        #expect(await fixture.host.isReady(token: second))
        #expect((await fixture.host.drain(deadline: .now + .seconds(2))).completed)
    }

    @Test("coalesced lifecycle changes reconcile exact ready tokens")
    func lifecycleChanges() async throws {
        let fixture = try Fixture()
        await fixture.host.start()
        let stream = await fixture.host.changes()
        var iterator = stream.makeAsyncIterator()
        let initialRevision = try #require(await iterator.next())
        guard case .ready(let token) = try await fixture.activate().value else {
            Issue.record("expected ready"); return
        }
        let readyRevision = try #require(await iterator.next())
        #expect(readyRevision > initialRevision)
        #expect(await fixture.host.readyTokens() == [token])
        #expect(await fixture.host.isReady(token: token))
        await fixture.host.beginDrain()
        let drainingRevision = try #require(await iterator.next())
        #expect(drainingRevision > readyRevision)
        #expect(!(await fixture.host.isReady(token: token)))
        #expect(await fixture.host.readyTokens().isEmpty)
        #expect((await fixture.host.drain(deadline: .now + .seconds(2))).completed)
    }

    @Test("snapshot recovery bypasses a held command lane and pins lifecycle until actual settlement", arguments: [false, true])
    func recoveryBatchOwnsAdmittedRooms(qualificationLost: Bool) async throws {
        let owner = try V2RoomDataOwner(shardID: "batch", epoch: 0)
        let identity = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let config = try V2RoomRuntimeConfiguration(maximumActiveRooms: 4,
            maximumConcurrentRestores: 2, maximumPendingActivations: 4,
            maximumConcurrentReservations: 4)
        let store = FakeLeaseStore(renewGate: nil, acquireGate: nil, releaseFailures: 0,
            missingRoom: false, occupiedByOther: false, unknownAcquire: false,
            renewFailures: [], repeatedRenewFailure: nil)
        let budget = V2RoomCommandBudget(configuration: config)
        let gate = Gate()
        let invalidations = ReadInvalidationProbe()
        let qualification = try V2ActorServiceQualification(localNodeID: "a", roster: ["a", "b", "c"])
        _ = qualification.update(witnesses: ["b": .now + .seconds(10)])
        let host = V2RoomActivationHost<V2RoomRequest, V2RoomResponse>(identity: identity,
            leaseStore: store, configuration: config, budget: budget,
            classify: { $0.turnSchedulingClass }, factory: .init(recoveryBatch: { items in
                #expect(items.count == 3)
                #expect(Set(items.map { $0.token.roomID }).count == 2)
                #expect(Set(items.map { $0.query.actorUserID }).count == 2)
                await gate.wait()
                return .committed(items.map { .init(token: $0.token, query: $0.query,
                    outcome: .result(.recovery(.state(.unavailable)))) })
            }) { _ in
                .init(restore: { _ in }, execute: { turn in
                    .committed(turn.items.map { _ in .recovery(.state(.unavailable)) })
                }, invalidateReservation: { _ in await invalidations.record() }, close: {})
            }, qualification: qualification)
        await host.start()
        let roomA = RoomID(uuid: UUID()), roomB = RoomID(uuid: UUID())
        guard case .ready(let a) = try await host.activate(roomID: roomA, owner: owner, deadline: .now + .seconds(2)),
              case .ready(let b) = try await host.activate(roomID: roomB, owner: owner, deadline: .now + .seconds(2)) else {
            Issue.record("expected two ready activations"); _ = await host.stop(deadline: .now + .seconds(2)); return
        }
        let viewerA = UserID(uuid: UUID()), viewerB = UserID(uuid: UUID())
        let missing = V2RoomActivationToken(roomID: RoomID(uuid: UUID()), owner: owner,
            activationEpoch: try .init(1), host: identity)
        let end = ContinuousClock.now + .seconds(3)
        let items: [V2RoomRecoveryBatchCallItem] = [(a, viewerA), (a, viewerB), (b, viewerA), (missing, viewerA)].map {
            .init(token: $0.0, query: .init(roomID: $0.0.roomID, actorUserID: $0.1, kind: .state), deadline: end)
        }
        let heldWrite = try await host.reserve(token: a, requestID: UUID(), deadline: end)
        try await host.markReservationDispatched(heldWrite)
        let work = Task { await host.invokeRecoveryBatch(items: items, deadline: end) }
        let siblings = (0..<3).map { _ in Task { await host.invokeRecoveryBatch(items: items, deadline: end) } }
        do {
            try await gate.waitForEntries(4)
            let overflow = await host.invokeRecoveryBatch(items: items, deadline: end)
            #expect(overflow.allSatisfy { $0.outcome == .failure(.notAccepted(.overloaded)) })
            #expect(budget.snapshot().reservationCount == 1)
            #expect(await invalidations.count == 0)
            #expect(await host.finishReservation(heldWrite, completion: .committed))
            #expect(await invalidations.count == 1)
            if qualificationLost {
                qualification.revoke()
                await host.qualificationDidChange()
            } else { work.cancel() }
            await host.beginDrain()
            #expect(!(await host.drain(deadline: .now + .milliseconds(30))).completed)
            #expect(await store.releaseCount == 0)
            #expect(budget.snapshot().reservationCount == 0)
            await gate.open()
            let values = await work.value
            for sibling in siblings { _ = await sibling.value }
            #expect(values.count == 4)
            #expect(values[3].outcome == .failure(.notAccepted(.staleActivation)))
            if qualificationLost {
                #expect(values.prefix(3).allSatisfy { $0.outcome == .failure(.notAccepted(.leaseLost)) })
            }
            #expect(await invalidations.count == 1)
            #expect((await host.stop(deadline: .now + .seconds(2))).completed)
            #expect(budget.snapshot().reservationCount == 0)
        } catch {
            await gate.open(); _ = await work.value
            for sibling in siblings { _ = await sibling.value }
            _ = await host.finishReservation(heldWrite, completion: .rolledBack)
            _ = await host.stop(deadline: .now + .seconds(2)); throw error
        }
    }

    @Test("pure room-log pulls retain bounded read pins without retiring the write lane")
    func pureRoomLogPullOwnsBudgetAndLifecycle() async throws {
        let owner = try V2RoomDataOwner(shardID: "pull", epoch: 0)
        let identity = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let configuration = try V2RoomRuntimeConfiguration(maximumActiveRooms: 2,
            maximumConcurrentRestores: 1, maximumPendingActivations: 2,
            maximumQueuedCommandsPerRoom: 3, maximumQueuedCommandsPerHost: 4,
            maximumCommandsPerTurn: 3, maximumConcurrentReservations: 2)
        let store = FakeLeaseStore(renewGate: nil, acquireGate: nil, releaseFailures: 0,
            missingRoom: false, occupiedByOther: false, unknownAcquire: false,
            renewFailures: [], repeatedRenewFailure: nil)
        let budget = V2RoomCommandBudget(configuration: configuration)
        let readGate = Gate(), lateGate = Gate()
        let laneExecutions = ReadInvalidationProbe(), invalidations = ReadInvalidationProbe()
        let qualification = try V2ActorServiceQualification(localNodeID: "a", roster: ["a", "b", "c"])
        _ = qualification.update(witnesses: ["b": .now + .seconds(10)])
        let host = V2RoomActivationHost<V2RoomRequest, V2RoomResponse>(identity: identity,
            leaseStore: store, configuration: configuration, budget: budget,
            classify: { $0.turnSchedulingClass }, factory: .init(pureRoomLogPull: { token, request, _ in
                guard case .roomLog(.pull(let pull)) = request, pull.roomID == token.roomID else {
                    return .rolledBack(.invalidRequest)
                }
                if pull.afterRoomSequence == 0 { await readGate.wait() }
                else { await lateGate.wait() }
                if pull.pageSize == 1 { return .outcomeUnknown }
                return .committed(.recovery(.state(.unavailable)))
            }) { _ in
                .init(restore: { _ in }, execute: { turn in
                    await laneExecutions.record()
                    return .committed(turn.items.map { _ in .recovery(.state(.unavailable)) })
                }, invalidateReservation: { _ in await invalidations.record() }, close: {})
            }, qualification: qualification)
        await host.start()
        let room = RoomID(uuid: UUID()), viewer = UserID(uuid: UUID())
        guard case .ready(let token) = try await host.activate(roomID: room, owner: owner, deadline: .now + .seconds(2)) else {
            _ = await host.stop(deadline: .now + .seconds(2)); throw TestFailure.restore
        }
        let end = ContinuousClock.now + .seconds(5)
        let request = V2RoomRequest.roomLog(.pull(try .init(roomID: room, actorUserID: viewer,
            afterRoomSequence: 0, pageSize: 1)))
        let bytes = try request
        let heldWrite = try await host.reserve(token: token, requestID: UUID(), deadline: end)
        let successfulRead = V2RoomRequest.roomLog(.pull(try .init(roomID: room, actorUserID: viewer,
            afterRoomSequence: 0, pageSize: 2)))
        let successfulBytes = try successfulRead
        let reads = [successfulBytes, bytes].map { body in
            Task { try await host.invoke(token: token, request: body, deadline: end) }
        }
        var late: Task<V2RoomResponse, any Error>?
        var lateKnown: Task<V2RoomResponse, any Error>?
        do {
            try await readGate.waitForEntries(2)
            #expect(await laneExecutions.count == 0)
            #expect(budget.snapshot().commandCount == 3)
            reads[0].cancel()
            #expect(budget.snapshot().commandCount == 3)
            await #expect(throws: V2RoomCallFailure.notAccepted(.overloaded)) {
                _ = try await host.invoke(token: token, request: bytes, deadline: end)
            }
            await readGate.open()
            await expectFailure(.notAccepted(.cancelled), reads[0])
            await expectFailure(.outcomeUnknown, reads[1])
            #expect(await host.isReady(token: token))
            #expect(budget.snapshot().commandCount == 1)
            #expect(await invalidations.count == 0)
            #expect(await host.abortReservation(heldWrite))
            let subscribe = V2RoomRequest.roomLog(.subscribe(.init(roomID: room, actorUserID: viewer)))
            _ = try await host.invoke(token: token, request: subscribe, deadline: end)
            #expect(await laneExecutions.count == 1) // Subscribe retains the original lane.
            let second = V2RoomRequest.roomLog(.pull(try .init(roomID: room, actorUserID: viewer,
                afterRoomSequence: 1, pageSize: 1)))
            let secondBytes = try second
            late = Task { try await host.invoke(token: token, request: secondBytes, deadline: end) }
            let known = V2RoomRequest.roomLog(.pull(try .init(roomID: room, actorUserID: viewer,
                afterRoomSequence: 1, pageSize: 2)))
            let knownBytes = try known
            lateKnown = Task { try await host.invoke(token: token, request: knownBytes, deadline: end) }
            try await lateGate.waitForEntries(2)
            qualification.revoke()
            await host.qualificationDidChange()
            #expect(!(await host.drain(deadline: .now + .milliseconds(20))).completed)
            #expect(budget.snapshot().commandCount == 2)
            await lateGate.open()
            if let late { await expectFailure(.outcomeUnknown, late) }
            if let lateKnown {
                do { _ = try await lateKnown.value; Issue.record("old-proof read unexpectedly succeeded") }
                catch { #expect(error as? V2RoomCallFailure == .notAccepted(.staleActivation) ||
                    error as? V2RoomCallFailure == .notAccepted(.leaseLost)) }
            }
            #expect(budget.snapshot().commandCount == 0)
        } catch {
            await readGate.open(); await lateGate.open()
            for read in reads { _ = await read.result }
            if let late { _ = await late.result }
            if let lateKnown { _ = await lateKnown.result }
            _ = await host.abortReservation(heldWrite)
            _ = await host.stop(deadline: .now + .seconds(2)); throw error
        }
        #expect((await host.stop(deadline: .now + .seconds(2))).completed)
    }

    @Test("pure subscription renewal bypasses a held write turn and pins its exact lifecycle")
    func pureRenewalOwnsBudgetAndLifecycle() async throws {
        let owner = try V2RoomDataOwner(shardID: "renew", epoch: 0)
        let identity = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let configuration = try V2RoomRuntimeConfiguration(maximumQueuedCommandsPerRoom: 3,
            maximumQueuedCommandsPerHost: 4, maximumCommandsPerTurn: 3)
        let store = FakeLeaseStore(renewGate: nil, acquireGate: nil, releaseFailures: 0,
            missingRoom: false, occupiedByOther: false, unknownAcquire: false,
            renewFailures: [], repeatedRenewFailure: nil)
        let budget = V2RoomCommandBudget(configuration: configuration), gate = Gate()
        let lane = ReadInvalidationProbe()
        let qualification = try V2ActorServiceQualification(localNodeID: "a", roster: ["a", "b", "c"])
        _ = qualification.update(witnesses: ["b": .now + .seconds(10)])
        let host = V2RoomActivationHost<V2RoomRequest, V2RoomResponse>(identity: identity,
            leaseStore: store, configuration: configuration, budget: budget,
            classify: { $0.turnSchedulingClass }, factory: .init(pureSubscriptionRenew: { token, request, _, validUntil in
                #expect(validUntil > .now)
                guard case .roomSubscription(.renew(let command)) = request, command.roomID == token.roomID else {
                    return .rolledBack(.invalidRequest)
                }
                await gate.wait()
                if command.appliedControlSequence == 1 { return .outcomeUnknown }
                return .committed(.roomSubscription(.failure(.unavailable)))
            }) { _ in
                .init(restore: { _ in }, execute: { turn in
                    await lane.record(); return .committed(turn.items.map { _ in .roomSubscription(.activated) })
                }, invalidateReservation: { _ in }, close: {})
            }, qualification: qualification)
        await host.start()
        let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID())
        guard case .ready(let token) = try await host.activate(roomID: room, owner: owner, deadline: .now + .seconds(2)) else {
            throw TestFailure.restore
        }
        let peer = V2GatewayRealtimeDescriptor(identity: .init(nodeID: "g", serviceID: "g", incarnationID: UUID()),
            endpointReference: Data([1]), address: "127.0.0.1", port: 9000)
        let fence = V2RoomSubscriptionFence(activation: token, subscriptionID: UUID(), generation: 1, baselineSequence: 0)
        func bytes(_ sequence: UInt64) throws -> V2RoomRequest {
            try V2RoomRequest.roomSubscription(.renew(.init(roomID: room, actorUserID: user,
                gatewayDescriptor: peer, expectedFence: fence, appliedControlSequence: sequence)))
        }
        let end = ContinuousClock.now + .seconds(5)
        let held = try await host.reserve(token: token, requestID: UUID(), deadline: end)
        let unknownBytes = try bytes(1), knownBytes = try bytes(2)
        let unknown = Task { try await host.invoke(token: token, request: unknownBytes, deadline: end) }
        let cancelled = Task { try await host.invoke(token: token, request: knownBytes, deadline: end) }
        do {
            try await gate.waitForEntries(2)
            #expect(await lane.count == 0)
            #expect(budget.snapshot().commandCount == 3)
            cancelled.cancel()
            await #expect(throws: V2RoomCallFailure.notAccepted(.overloaded)) {
                _ = try await host.invoke(token: token, request: knownBytes, deadline: end)
            }
            await gate.open()
            await expectFailure(.outcomeUnknown, unknown)
            await expectFailure(.notAccepted(.cancelled), cancelled)
            #expect(await host.isReady(token: token))
            #expect(budget.snapshot().commandCount == 1)
            #expect(await host.abortReservation(held))
            let subscribe = V2RoomRequest.roomSubscription(.subscribe(.init(roomID: room, actorUserID: user,
                                                                           gatewayDescriptor: peer)))
            _ = try await host.invoke(token: token, request: subscribe, deadline: end)
            #expect(await lane.count == 1)
            qualification.revoke()
            await #expect(throws: V2RoomCallFailure.self) {
                _ = try await host.invoke(token: token, request: knownBytes, deadline: end)
            }
            #expect(budget.snapshot().commandCount == 0)
        } catch {
            await gate.open(); _ = await unknown.result; _ = await cancelled.result
            _ = await host.abortReservation(held); _ = await host.stop(deadline: .now + .seconds(2)); throw error
        }
        #expect((await host.stop(deadline: .now + .seconds(2))).completed)
    }

    private actor ReadInvalidationProbe {
        var count = 0
        func record() { count += 1 }
    }

    private func expectFailure<T: Sendable>(_ expected: V2RoomCallFailure,
                                             _ task: Task<T, any Error>) async {
        do { _ = try await task.value; Issue.record("unexpected success") }
        catch { #expect(error as? V2RoomCallFailure == expected) }
    }

    private func waitUntil(deadline: ContinuousClock.Instant = .now + .seconds(2),
                           _ condition: @escaping @Sendable () async -> Bool) async throws {
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
             occupiedByOther: Bool = false, unknownAcquire: Bool = false,
             renewFailures: [V2RoomActivationLeaseError] = [],
             repeatedRenewFailure: V2RoomActivationLeaseError? = nil,
             qualification: V2ActorServiceQualification = .standalone()) throws {
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
                                   occupiedByOther: occupiedByOther, unknownAcquire: unknownAcquire,
                                   renewFailures: renewFailures, repeatedRenewFailure: repeatedRenewFailure)
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
                }, qualification: qualification
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
                try await host.invoke(token: token, request: Command(value: 1),
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
        private var renewFailures: [V2RoomActivationLeaseError]
        private let repeatedRenewFailure: V2RoomActivationLeaseError?
        var acquireCount = 0
        var renewCount = 0
        var successfulRenewCount = 0
        var releaseCount = 0

        init(renewGate: Gate?, acquireGate: Gate?, releaseFailures: Int,
             missingRoom: Bool, occupiedByOther: Bool, unknownAcquire: Bool,
             renewFailures: [V2RoomActivationLeaseError], repeatedRenewFailure: V2RoomActivationLeaseError?) {
            self.renewGate = renewGate
            self.acquireGate = acquireGate
            self.releaseFailures = releaseFailures
            self.missingRoom = missingRoom
            self.occupiedByOther = occupiedByOther
            self.unknownAcquire = unknownAcquire
            self.renewFailures = renewFailures
            self.repeatedRenewFailure = repeatedRenewFailure
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
            if !renewFailures.isEmpty { throw renewFailures.removeFirst() }
            if let repeatedRenewFailure { throw repeatedRenewFailure }
            guard current[token.roomID]?.token == token else {
                throw V2RoomActivationLeaseError.activationChanged
            }
            let lease = try makeLease(token, duration: duration)
            successfulRenewCount += 1
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
            #expect(turn.context.activationValidUntil.map { $0 > .now } == true)
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

// Deliberately holds one lifecycle executor turn; bounded to avoid hanging the suite.
private extension V2RoomActivationHost {
    func holdLifecycleForTest(entered: DispatchSemaphore, release: DispatchSemaphore) {
        entered.signal()
        _ = release.wait(timeout: .now() + 2)
    }
}

// A bounded synchronous test barrier, never part of production scheduling.
private func hostTestWaitForEntered(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + 2) == .success
}
