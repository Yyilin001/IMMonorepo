import Foundation
import IMV2ServerApplication
import IMV2ServerContracts
import NIOCore
import Synchronization
import Testing
@testable import IMV2ServerInfrastructure

struct V2PhysicalDatabasePoolBorrowerTests {
    @Test("immediately granted capacity can wait for the EventLoop before publication")
    func grantedCapacityWaitsForLoop() async throws {
        let resources = makeV2DatabaseTestResources()
        let loop = resources.eventLoopGroup.next()
        let gate = V2PhysicalDatabaseLoanGate(eventLoop: loop, policy: try .init(
            maximumConnections: 1, reservedRenewalConnections: 0, maximumQueued: 1, maximumWait: .seconds(5)))
        let borrower = V2PhysicalDatabasePoolBorrower(gates: [gate], eventLoop: loop)
        let entered = Mutex(false), unblock = DispatchSemaphore(value: 0)
        loop.execute { entered.withLock { $0 = true }; unblock.wait() }
        let timeline = V2OwnerConnectionTimeline(), metrics = V2SendOperationBatchMetrics()
        timeline.configure(metrics)
        var request: V2PhysicalDatabasePoolBorrower.Request?
        do {
            let deadline = ContinuousClock.now + .seconds(2)
            while !entered.withLock({ $0 }), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            try #require(entered.withLock { $0 })
            let pending = V2OwnerConnectionTimeline.$current.withValue(timeline) {
                timeline.mark("pool_request_started")
                return borrower.request(loanClass: .ordinary, deadline: .now + .seconds(3))
            }
            request = pending
            // The gate already owns capacity while its NIO loop is held.
            #expect(gate.snapshot().classes[.ordinary]?.inFlight == 1)
            #expect(gate.snapshot().classes[.ordinary]?.queued == 0)
            #expect(timeline.marker("pool_assignment_published") == nil)
            try await Task.sleep(for: .milliseconds(15))
            unblock.signal()
            let assignment = try await pending.future.get()
            let timing = try #require(assignment.lease.timing)
            #expect(!timing.wasQueued && !timing.grantedOnEventLoop)
            timeline.flushAssignmentTiming()
            let stages = metrics.sendOperationBatchMetricsSnapshot().stages
            #expect(stages[.ownerGateOffLoopDelivery]?.count == 1)
            #expect((stages[.ownerGateDeliveryWait]?.totalMilliseconds ?? 0) >= 15)
            #expect(stages[.ownerGateQueuedCapacityWait]?.count == 0)
            assignment.lease.release(); borrower.close()
            await gate.shutdown(); await borrower.waitUntilSettled(); try await resources.shutdown()
        } catch {
            unblock.signal(); request?.cancel()
            if let request, let assignment = try? await request.future.get() { assignment.lease.release() }
            borrower.close(); await gate.shutdown(); await borrower.waitUntilSettled()
            try await resources.shutdown(); throw error
        }
    }
    @Test("combined immediate delivery completes once on its physical loop")
    func combinedImmediateDelivery() async throws {
        let resources = makeV2DatabaseTestResources()
        let loop = resources.eventLoopGroup.next()
        let gate = V2PhysicalDatabaseLoanGate(eventLoop: loop, policy: try .init(
            maximumConnections: 1, reservedRenewalConnections: 0, maximumQueued: 1, maximumWait: .seconds(5)))
        let request = try #require(gate.requestIfAvailable(loanClass: .ordinary,
            combineImmediateDelivery: true))
        let first = loop.makePromise(of: Bool.self), second = loop.makePromise(of: Bool.self)
        request.whenComplete { result in
            switch result {
            case .success: first.succeed(loop.inEventLoop)
            case .failure(let error): first.fail(error)
            }
        }
        request.whenComplete { result in
            switch result {
            case .success: second.succeed(loop.inEventLoop)
            case .failure(let error): second.fail(error)
            }
        }
        // A granted lease survives queued-only cancellation until its owner
        // returns it; repeated registration never grants a second loan.
        request.cancel()
        let lease = try await request.future.get()
        #expect(try await first.futureResult.get())
        #expect(try await second.futureResult.get())
        #expect(gate.snapshot().classes[.ordinary]?.granted == 1)
        lease.release(); lease.release()
        #expect(gate.snapshot().classes[.ordinary]?.inFlight == 0)
        await gate.shutdown(); try await resources.shutdown()
    }
    @Test("scheduled assignment enters the selected peer loop without a facade callback")
    func assignmentCallbackUsesSelectedLoop() async throws {
        let resources = makeV2DatabaseTestResources(eventLoopThreads: 2)
        let facade = resources.eventLoopGroup.next(), peer = resources.eventLoopGroup.next()
        let policy = try V2PhysicalDatabaseLoanPolicy(maximumConnections: 1,
            reservedRenewalConnections: 0, maximumQueued: 1, maximumWait: .seconds(5))
        let gates = [facade, peer].map { V2PhysicalDatabaseLoanGate(eventLoop: $0, policy: policy) }
        let borrower = V2PhysicalDatabasePoolBorrower(gates: gates, eventLoop: facade)
        let held = try await gates[0].acquire(loanClass: .ordinary).get()
        let observed = peer.makePromise(of: Bool.self)
        let callbacks = Mutex(0)
        let request = borrower.request(loanClass: .ordinary, deadline: .now + .seconds(3), onAssignment: { result in
            callbacks.withLock { $0 += 1 }
            switch result {
            case .success(let assignment): observed.succeed(assignment.index == 1 && peer.inEventLoop && !facade.inEventLoop)
            case .failure(let error): observed.fail(error)
            }
        })
        do {
            #expect(try await observed.futureResult.get())
            let assignment = try await request.future.get()
            #expect(callbacks.withLock { $0 } == 1)
            assignment.lease.release()
            held.release(); borrower.close()
            for gate in gates { await gate.shutdown() }
            await borrower.waitUntilSettled(); try await resources.shutdown()
        } catch {
            request.cancel(); held.release(); borrower.close()
            if let assignment = try? await request.future.get() { assignment.lease.release() }
            for gate in gates { await gate.shutdown() }
            await borrower.waitUntilSettled(); try await resources.shutdown()
            throw error
        }
    }
    @Test("repeated capacity notifications keep a constant callback path")
    func repeatedCapacityNotifications() async throws {
        let resources = makeV2DatabaseTestResources()
        let loop = resources.eventLoopGroup.next()
        let gate = V2PhysicalDatabaseLoanGate(eventLoop: loop, policy: try .init(
            maximumConnections: 1, reservedRenewalConnections: 0,
            maximumQueued: 1, maximumWait: .seconds(5)))
        let notifications = Mutex(0)
        gate.observeCapacityReturns { notifications.withLock { $0 += 1 } }
        for _ in 0..<20_000 {
            let lease = try await gate.acquire(loanClass: .ordinary).get()
            lease.release()
        }
        #expect(notifications.withLock { $0 } == 20_000)
        #expect(gate.snapshot().classes[.ordinary]?.inFlight == 0)
        await gate.shutdown()
        try await resources.shutdown()
    }

    @Test("peer capacity return schedules selection outside the loan completion stack")
    func peerReturnDefersSelection() async throws {
        let resources = makeV2DatabaseTestResources()
        let loop = resources.eventLoopGroup.next()
        let policy = try V2PhysicalDatabaseLoanPolicy(maximumConnections: 1,
            reservedRenewalConnections: 0, maximumQueued: 1, maximumWait: .seconds(5))
        let gates = (0..<2).map { _ in V2PhysicalDatabaseLoanGate(eventLoop: loop, policy: policy) }
        let borrower = V2PhysicalDatabasePoolBorrower(gates: gates, eventLoop: loop)
        var held: [V2PhysicalDatabaseLoanLease] = []
        for gate in gates { held.append(try await gate.acquire(loanClass: .ordinary).get()) }
        let peer = held[1], exposed = Mutex(false)
        let request = try await loop.submit {
            let request = borrower.request(loanClass: .ordinary, deadline: .now + .seconds(3))
            request.future.whenSuccess { _ in exposed.withLock { $0 = true } }
            peer.release()
            #expect(!exposed.withLock { $0 })
            return request
        }.get()
        do {
            let assignment = try await request.future.get()
            #expect(assignment.index == 1)
            #expect(gates[0].snapshot().classes[.ordinary]?.inFlight == 1)
            #expect(borrower.pendingCount == 0)
            assignment.lease.release()
            borrower.close()
            for lease in held { lease.release() }
            for gate in gates { await gate.shutdown() }
            await borrower.waitUntilSettled()
            try await resources.shutdown()
        } catch {
            borrower.close(); request.cancel()
            for lease in held { lease.release() }
            for gate in gates { await gate.shutdown() }
            await borrower.waitUntilSettled()
            try await resources.shutdown()
            throw error
        }
    }

    @Test("immediate pool queue rejection retains no borrower metadata")
    func immediateRejectionIsBounded() async throws {
        let resources = makeV2DatabaseTestResources()
        let loop = resources.eventLoopGroup.next()
        let gate = V2PhysicalDatabaseLoanGate(eventLoop: loop, policy: try .init(
            maximumConnections: 1, reservedRenewalConnections: 0,
            maximumQueued: 1, maximumWait: .seconds(5)))
        let borrower = V2PhysicalDatabasePoolBorrower(gates: [gate], eventLoop: loop)
        let held = try await gate.acquire(loanClass: .ordinary).get()
        let queued = borrower.request(loanClass: .ordinary, deadline: .now + .seconds(3))
        do {
            for _ in 0..<100 {
                let rejected = borrower.request(loanClass: .ordinary, deadline: .now + .seconds(3))
                #expect(borrower.pendingCount == 1)
                do {
                    let assignment = try await rejected.future.get()
                    assignment.lease.release()
                    Issue.record("queue-full request cannot receive a loan")
                } catch { #expect(error as? V2PhysicalDatabaseLoanFailure == .queueFull) }
            }
            #expect(gate.snapshot().classes[.ordinary]?.queued == 1)
            #expect(gate.snapshot().classes[.ordinary]?.rejected == 100)
            queued.cancel()
            do {
                let assignment = try await queued.future.get()
                assignment.lease.release()
                Issue.record("queued cancellation cannot expose a loan")
            } catch { #expect(error as? V2PhysicalDatabaseLoanFailure == .cancelled) }
            #expect(borrower.pendingCount == 0)
            borrower.close(); held.release()
            await gate.shutdown(); await borrower.waitUntilSettled()
            try await resources.shutdown()
        } catch {
            borrower.close(); queued.cancel(); held.release()
            _ = try? await queued.future.get()
            await gate.shutdown(); await borrower.waitUntilSettled()
            try await resources.shutdown()
            throw error
        }
    }

    @Test("queued peer borrowing cancels, expires and closes without reclaiming actual held loans",
          arguments: ["cancel", "timeout", "close"])
    func queuedSettlement(mode: String) async throws {
        let resources = makeV2DatabaseTestResources()
        let loop = resources.eventLoopGroup.next()
        let policy = try V2PhysicalDatabaseLoanPolicy(maximumConnections: 1,
            reservedRenewalConnections: 0, maximumQueued: 1, maximumWait: .seconds(5))
        let gates = (0..<2).map { _ in V2PhysicalDatabaseLoanGate(eventLoop: loop, policy: policy) }
        let borrower = V2PhysicalDatabasePoolBorrower(gates: gates, eventLoop: loop)
        var held: [V2PhysicalDatabaseLoanLease] = []
        for gate in gates { held.append(try await gate.acquire(loanClass: .ordinary).get()) }
        let request = borrower.request(loanClass: .ordinary,
            deadline: .now + (mode == "timeout" ? .milliseconds(100) : .seconds(3)))
        #expect(gates.reduce(0) { $0 + ($1.snapshot().classes[.ordinary]?.queued ?? 0) } == 1)
        var shutdowns: [Task<Void, Never>] = []
        if mode == "cancel" { request.cancel() }
        if mode == "close" {
            borrower.close()
            shutdowns = gates.map { gate in Task { await gate.shutdown() } }
        }
        do {
            do {
                let assignment = try await request.future.get()
                assignment.lease.release()
                Issue.record("a settled queued demand cannot expose a loan")
            } catch {
                let expected: V2PhysicalDatabaseLoanFailure = mode == "cancel" ? .cancelled :
                    mode == "timeout" ? .timedOut : .closed
                #expect(error as? V2PhysicalDatabaseLoanFailure == expected)
            }
            #expect(gates.reduce(0) { $0 + ($1.snapshot().classes[.ordinary]?.queued ?? 0) } == 0)
            #expect(gates.reduce(0) { $0 + ($1.snapshot().classes[.ordinary]?.inFlight ?? 0) } == 2)
            borrower.close()
            await borrower.waitUntilSettled()
            for lease in held { lease.release() }
            for shutdown in shutdowns { await shutdown.value }
            for gate in gates { await gate.shutdown() }
            #expect(gates.allSatisfy { $0.snapshot().classes[.ordinary]?.inFlight == 0 })
            try await resources.shutdown()
        } catch {
            borrower.close()
            for lease in held { lease.release() }
            for shutdown in shutdowns { await shutdown.value }
            for gate in gates { await gate.shutdown() }
            await borrower.waitUntilSettled()
            try await resources.shutdown()
            throw error
        }
    }
    @Test("room watchdog cancellation removes the actual pool ticket without releasing active loans",
          arguments: [false, true])
    func acquisitionCancellationBridge(cancelBeforeInstall: Bool) async throws {
        let resources = makeV2DatabaseTestResources()
        let loop = resources.eventLoopGroup.next()
        let policy = try V2PhysicalDatabaseLoanPolicy(maximumConnections: 1,
            reservedRenewalConnections: 0, maximumQueued: 1, maximumWait: .seconds(5))
        let gate = V2PhysicalDatabaseLoanGate(eventLoop: loop, policy: policy)
        let borrower = V2PhysicalDatabasePoolBorrower(gates: [gate], eventLoop: loop)
        let held = try await gate.acquire(loanClass: .ordinary).get()
        let cancellation = V2ConnectionAcquisitionCancellation()
        if cancelBeforeInstall { cancellation.cancel() }
        let request = borrower.request(loanClass: .ordinary, deadline: .now + .seconds(3))
        cancellation.install(request.cancel)
        cancellation.cancel(); cancellation.cancel()
        do {
            do {
                let assignment = try await request.future.get()
                assignment.lease.release()
                Issue.record("cancelled pool ticket unexpectedly acquired a loan")
            } catch { #expect(error as? V2PhysicalDatabaseLoanFailure == .cancelled) }
            #expect(gate.snapshot().classes[.ordinary]?.queued == 0)
            #expect(gate.snapshot().classes[.ordinary]?.inFlight == 1)
            #expect(borrower.pendingCount == 0)
            borrower.close(); held.release()
            await gate.shutdown(); await borrower.waitUntilSettled()
            try await resources.shutdown()
        } catch {
            request.cancel(); borrower.close(); held.release()
            await gate.shutdown(); await borrower.waitUntilSettled()
            try? await resources.shutdown(); throw error
        }
    }

}
