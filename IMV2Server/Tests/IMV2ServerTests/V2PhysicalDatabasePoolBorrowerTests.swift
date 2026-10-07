import Foundation
import NIOCore
import Synchronization
import Testing
@testable import IMV2ServerInfrastructure

struct V2PhysicalDatabasePoolBorrowerTests {
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
