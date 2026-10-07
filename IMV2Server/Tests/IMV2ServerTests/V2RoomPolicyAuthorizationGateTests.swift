import Foundation
@testable import IMV2ServerApplication
import Testing

@Suite("room policy authorization lifecycle", .timeLimit(.minutes(1)))
struct V2RoomPolicyAuthorizationGateTests {
    private let activation = UUID()
    private let initial = V2RoomPolicyAuthorizationGate.Versions(sender: 1, recipient: 1, pair: 1)

    private func policy(_ versions: V2RoomPolicyAuthorizationGate.Versions,
                        blocked: Bool = false) -> V2RoomPolicyAuthorizationGate.Policy {
        .init(versions: versions, senderActive: true, recipientActive: true,
              blocked: blocked, friend: true, allowsStrangers: false)
    }

    @Test("account-only versions reject mixed policy shapes and preserve complete facts")
    func accountOnlyPolicy() async throws {
        let gate = V2RoomPolicyAuthorizationGate(activation: activation, ownerEpoch: 1, maximumInFlight: 1)
        let lease = V2RoomPolicyAuthorizationGate.Lease(id: UUID(), activation: activation,
            ownerEpoch: 1, generation: 1, validUntil: .now + .seconds(30))
        let facts = Data("account-facts".utf8)
        try await gate.install(.init(accountVersion: 3, senderActive: true, senderFacts: facts), lease: lease)
        let permit = try await gate.acquire(callerDeadline: .now + .seconds(10))
        #expect(permit.versions == .init(accountSender: 3))
        try await gate.settled(permit)
        let next = V2RoomPolicyAuthorizationGate.Lease(id: UUID(), activation: activation,
            ownerEpoch: 1, generation: 2, validUntil: .now + .seconds(30))
        await #expect(throws: V2RoomPolicyAuthorizationGate.Failure.staleVersion) {
            try await gate.install(.init(accountVersion: 3, senderActive: true, senderFacts: Data("changed".utf8)), lease: next)
        }
        await #expect(throws: V2RoomPolicyAuthorizationGate.Failure.staleVersion) {
            try await gate.install(policy(.init(sender: 100, recipient: 100, pair: 100)), lease: next)
        }
        await #expect(throws: V2RoomPolicyAuthorizationGate.Failure.staleVersion) {
            try await gate.install(.init(versions: .init(accountSender: 4), senderActive: true,
                recipientActive: true, blocked: true, friend: true, allowsStrangers: false, senderFacts: facts), lease: next)
        }
        try await gate.install(.init(accountVersion: 4, senderActive: false, senderFacts: facts), lease: next)
        await #expect(throws: V2RoomPolicyAuthorizationGate.Failure.senderInactive) {
            try await gate.acquire(callerDeadline: .now + .seconds(10))
        }
        #expect(await gate.snapshot().inFlight == 0)
        await gate.shutdown()
    }

    @Test("stranger policy advances independently and equal stranger versions cannot change permission")
    func independentStrangerVersion() async throws {
        let gate = V2RoomPolicyAuthorizationGate(activation: activation, ownerEpoch: 1, maximumInFlight: 1)
        let first = V2RoomPolicyAuthorizationGate.Lease(id: UUID(), activation: activation,
            ownerEpoch: 1, generation: 1, validUntil: .now + .seconds(30))
        try await gate.install(.init(versions: .init(sender: 1, recipient: 1, pair: 1, stranger: 1),
            senderActive: true, recipientActive: true, blocked: false, friend: false, allowsStrangers: true), lease: first)
        let second = V2RoomPolicyAuthorizationGate.Lease(id: UUID(), activation: activation,
            ownerEpoch: 1, generation: 2, validUntil: .now + .seconds(30))
        try await gate.install(.init(versions: .init(sender: 1, recipient: 1, pair: 1, stranger: 2),
            senderActive: true, recipientActive: true, blocked: false, friend: false, allowsStrangers: false), lease: second)
        await #expect(throws: V2RoomPolicyAuthorizationGate.Failure.strangerForbidden) {
            try await gate.acquire(callerDeadline: .now + .seconds(5))
        }
        let third = V2RoomPolicyAuthorizationGate.Lease(id: UUID(), activation: activation,
            ownerEpoch: 1, generation: 3, validUntil: .now + .seconds(30))
        await #expect(throws: V2RoomPolicyAuthorizationGate.Failure.staleVersion) {
            try await gate.install(.init(versions: .init(sender: 1, recipient: 2, pair: 1, stranger: 2),
                senderActive: true, recipientActive: true, blocked: false, friend: false, allowsStrangers: true), lease: third)
        }
        await gate.shutdown()
    }

    @Test("only a newer relationship can change whether stranger permission is required")
    func friendBranchTransition() async throws {
        let gate = V2RoomPolicyAuthorizationGate(activation: activation, ownerEpoch: 1, maximumInFlight: 1)
        func lease(_ generation: Int64) -> V2RoomPolicyAuthorizationGate.Lease {
            .init(id: UUID(), activation: activation, ownerEpoch: 1, generation: generation, validUntil: .now + .seconds(30))
        }
        try await gate.install(.init(versions: .init(sender: 1, recipient: 1, pair: 1, stranger: 7),
            senderActive: true, recipientActive: true, blocked: false, friend: false, allowsStrangers: true), lease: lease(1))
        await #expect(throws: V2RoomPolicyAuthorizationGate.Failure.staleVersion) {
            try await gate.install(.init(versions: .init(sender: 1, recipient: 1, pair: 1, stranger: nil),
                senderActive: true, recipientActive: true, blocked: false, friend: true, allowsStrangers: false), lease: lease(2))
        }
        try await gate.install(.init(versions: .init(sender: 1, recipient: 1, pair: 2, stranger: nil),
            senderActive: true, recipientActive: true, blocked: false, friend: true, allowsStrangers: false), lease: lease(2))
        let permit = try await gate.acquire(callerDeadline: .now + .seconds(5))
        try await gate.settled(permit)
        await #expect(throws: V2RoomPolicyAuthorizationGate.Failure.staleVersion) {
            try await gate.install(.init(versions: .init(sender: 1, recipient: 1, pair: 3, stranger: nil),
                senderActive: true, recipientActive: true, blocked: false, friend: false, allowsStrangers: false), lease: lease(3))
        }
        await #expect(throws: V2RoomPolicyAuthorizationGate.Failure.staleVersion) {
            try await gate.install(.init(versions: .init(sender: 1, recipient: 1, pair: 3, stranger: 6),
                senderActive: true, recipientActive: true, blocked: false, friend: false, allowsStrangers: true), lease: lease(3))
        }
        try await gate.install(.init(versions: .init(sender: 1, recipient: 1, pair: 3, stranger: 8),
            senderActive: true, recipientActive: true, blocked: false, friend: false, allowsStrangers: false), lease: lease(3))
        await #expect(throws: V2RoomPolicyAuthorizationGate.Failure.strangerForbidden) {
            try await gate.acquire(callerDeadline: .now + .seconds(5))
        }
        await gate.shutdown()
    }

    @Test("revocation closes admission before waiting and cancellation never releases actual work")
    func revokeWaitsForActualSettlement() async throws {
        let gate = V2RoomPolicyAuthorizationGate(activation: activation, ownerEpoch: 1, maximumInFlight: 2)
        let lease = V2RoomPolicyAuthorizationGate.Lease(id: UUID(), activation: activation,
            ownerEpoch: 1, generation: 1, validUntil: .now + .seconds(30))
        try await gate.install(policy(initial), lease: lease)
        let permit = try await gate.acquire(callerDeadline: .now + .seconds(10))
        let first = Task { await gate.revoke(leaseID: lease.id) }
        let repeated = Task { await gate.revoke(leaseID: lease.id) }
        await observe { await gate.snapshot().waitingForSettlement == 2 }
        first.cancel()
        await #expect(throws: V2RoomPolicyAuthorizationGate.Failure.unavailable) {
            try await gate.acquire(callerDeadline: .now + .seconds(10))
        }
        #expect(await gate.snapshot().inFlight == 1)
        let shutdown = Task { await gate.shutdown() }
        await observe { await gate.snapshot().waitingForSettlement == 3 }
        try await gate.settled(permit)
        #expect(await first.value)
        #expect(await repeated.value)
        await shutdown.value
        #expect(await gate.snapshot().inFlight == 0)
        await #expect(throws: V2RoomPolicyAuthorizationGate.Failure.invalidPermit) {
            try await gate.settled(permit)
        }
    }

    @Test("revoked registration cannot be resurrected by a delayed snapshot or revoke")
    func refreshAndRevokeAreFenced() async throws {
        let gate = V2RoomPolicyAuthorizationGate(activation: activation, ownerEpoch: 1, maximumInFlight: 1)
        let lease = V2RoomPolicyAuthorizationGate.Lease(id: UUID(), activation: activation,
            ownerEpoch: 1, generation: 1, validUntil: .now + .seconds(30))
        try await gate.install(policy(initial), lease: lease)
        #expect(await gate.revoke(leaseID: lease.id))
        await #expect(throws: V2RoomPolicyAuthorizationGate.Failure.staleVersion) {
            try await gate.install(policy(initial), lease: lease)
        }
        let next = V2RoomPolicyAuthorizationGate.Lease(id: UUID(), activation: activation,
            ownerEpoch: 1, generation: 2, validUntil: .now + .seconds(30))
        let blocked = policy(.init(sender: 1, recipient: 1, pair: 2), blocked: true)
        try await gate.install(blocked, lease: next)
        #expect(await gate.revoke(leaseID: lease.id) == false)
        await #expect(throws: V2RoomPolicyAuthorizationGate.Failure.blocked) {
            try await gate.acquire(callerDeadline: .now + .seconds(10))
        }
        await #expect(throws: V2RoomPolicyAuthorizationGate.Failure.staleVersion) {
            try await gate.install(policy(initial), lease: next)
        }
        await gate.shutdown()
    }

    @Test("expired lease refuses sends while its prior execution retains ownership")
    func expiredLeaseDoesNotSettleSQL() async throws {
        let origin = ContinuousClock.now
        let clock = PolicyGateTestClock(origin)
        let gate = V2RoomPolicyAuthorizationGate(activation: activation, ownerEpoch: 1,
            maximumInFlight: 1, now: { clock.now() })
        let lease = V2RoomPolicyAuthorizationGate.Lease(id: UUID(), activation: activation,
            ownerEpoch: 1, generation: 1, validUntil: origin + .seconds(1))
        try await gate.install(policy(initial), lease: lease)
        let permit = try await gate.acquire(callerDeadline: origin + .seconds(30))
        #expect(permit.deadline == lease.validUntil)
        clock.advance(to: origin + .seconds(2))
        await #expect(throws: V2RoomPolicyAuthorizationGate.Failure.expired) {
            try await gate.acquire(callerDeadline: origin + .seconds(30))
        }
        let revoke = Task { await gate.revoke(leaseID: lease.id) }
        await observe { await gate.snapshot().waitingForSettlement == 1 }
        #expect(await gate.snapshot().inFlight == 1)
        try await gate.settled(permit)
        #expect(await revoke.value)
    }

    @Test("one room's held transaction cannot block a peer room or release its permits")
    func roomGatesAreIndependent() async throws {
        let first = V2RoomPolicyAuthorizationGate(activation: activation, ownerEpoch: 1, maximumInFlight: 1)
        let second = V2RoomPolicyAuthorizationGate(activation: activation, ownerEpoch: 1, maximumInFlight: 1)
        let lease = V2RoomPolicyAuthorizationGate.Lease(id: UUID(), activation: activation,
            ownerEpoch: 1, generation: 1, validUntil: .now + .seconds(30))
        try await first.install(policy(initial), lease: lease)
        try await second.install(policy(initial), lease: lease)
        let held = try await first.acquire(callerDeadline: .now + .seconds(10))
        let revoke = Task { await first.revoke(leaseID: lease.id) }
        await observe { await first.snapshot().waitingForSettlement == 1 }
        let peer = try await second.acquire(callerDeadline: .now + .seconds(10))
        await #expect(throws: V2RoomPolicyAuthorizationGate.Failure.invalidPermit) {
            try await second.settled(held)
        }
        try await second.settled(peer)
        try await first.settled(held)
        #expect(await revoke.value)
        await first.shutdown(); await second.shutdown()
    }

    @Test("migration rejects an old activation and a bounded gate retains no rejected execution")
    func migrationAndCapacityFences() async throws {
        let gate = V2RoomPolicyAuthorizationGate(activation: activation, ownerEpoch: 2, maximumInFlight: 1)
        let old = V2RoomPolicyAuthorizationGate.Lease(id: UUID(), activation: activation,
            ownerEpoch: 1, generation: 1, validUntil: .now + .seconds(30))
        await #expect(throws: V2RoomPolicyAuthorizationGate.Failure.wrongActivation) {
            try await gate.install(policy(initial), lease: old)
        }
        let current = V2RoomPolicyAuthorizationGate.Lease(id: UUID(), activation: activation,
            ownerEpoch: 2, generation: 1, validUntil: .now + .seconds(30))
        try await gate.install(policy(initial), lease: current)
        let permit = try await gate.acquire(callerDeadline: .now + .seconds(10))
        await #expect(throws: V2RoomPolicyAuthorizationGate.Failure.overloaded) {
            try await gate.acquire(callerDeadline: .now + .seconds(10))
        }
        #expect(await gate.snapshot().inFlight == 1)
        try await gate.settled(permit)
        await gate.shutdown()
        await #expect(throws: V2RoomPolicyAuthorizationGate.Failure.unavailable) {
            try await gate.install(policy(initial), lease: current)
        }
    }

    @Test("changing an unrelated revision cannot smuggle changed account policy into a snapshot")
    func policyVersionsAreIndependent() async throws {
        let gate = V2RoomPolicyAuthorizationGate(activation: activation, ownerEpoch: 1, maximumInFlight: 1)
        let lease = V2RoomPolicyAuthorizationGate.Lease(id: UUID(), activation: activation,
            ownerEpoch: 1, generation: 1, validUntil: .now + .seconds(30))
        try await gate.install(policy(initial), lease: lease)
        #expect(await gate.revoke(leaseID: lease.id))
        let next = V2RoomPolicyAuthorizationGate.Lease(id: UUID(), activation: activation,
            ownerEpoch: 1, generation: 2, validUntil: .now + .seconds(30))
        let inconsistent = V2RoomPolicyAuthorizationGate.Policy(
            versions: .init(sender: 1, recipient: 1, pair: 2), senderActive: false,
            recipientActive: true, blocked: false, friend: true, allowsStrangers: false)
        await #expect(throws: V2RoomPolicyAuthorizationGate.Failure.staleVersion) {
            try await gate.install(inconsistent, lease: next)
        }
        let suspended = V2RoomPolicyAuthorizationGate.Policy(
            versions: .init(sender: 2, recipient: 1, pair: 2), senderActive: false,
            recipientActive: true, blocked: false, friend: true, allowsStrangers: false)
        try await gate.install(suspended, lease: next)
        await #expect(throws: V2RoomPolicyAuthorizationGate.Failure.senderInactive) {
            try await gate.acquire(callerDeadline: .now + .seconds(10))
        }
        #expect(await gate.snapshot().inFlight == 0)
        await gate.shutdown()
    }

    private func observe(_ condition: @Sendable () async -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()), ContinuousClock.now < deadline { await Task.yield() }
        #expect(await condition())
    }
}

private final class PolicyGateTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ContinuousClock.Instant
    init(_ value: ContinuousClock.Instant) { self.value = value }
    func now() -> ContinuousClock.Instant { lock.lock(); defer { lock.unlock() }; return value }
    func advance(to value: ContinuousClock.Instant) { lock.lock(); self.value = value; lock.unlock() }
}
