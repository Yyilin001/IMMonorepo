import Foundation
import IMV2Core
@testable import IMV2ServerContracts
@testable import IMV2ServerApplication
@testable import IMV2ServerGateway
import Testing

@Suite("Connection lease controller ownership")
struct V2ConnectionLeaseControllerTests {
    @Test("heartbeats do not grant unconfirmed database authority")
    func heartbeatDoesNotExtendAuthority() async throws {
        let store = ControllerLeaseStore()
        let controller = makeController(store)
        let id = UUID(), identity = makeIdentity()
        _ = try await controller.admit(connectionID: id,
            identity: identity, lifecycle: 1, publicationSuppressed: false, policy: .init(maximumConnectionsPerDevice: 2, maximumConnectionsPerUser: 8))
        let before = await controller.snapshot(connectionID: id)
        #expect(await controller.heartbeat(connectionID: id, lifecycle: 1))
        #expect(!(await controller.heartbeat(connectionID: id, lifecycle: 2)))
        #expect(await controller.snapshot(connectionID: id).deadline == before.deadline)
        #expect(await store.renewalCount == 0)
        await controller.finish()
    }

    @Test("failed renewal preserves the original confirmed deadline")
    func failureDoesNotExtendAuthority() async throws {
        let store = ControllerLeaseStore(failRenewal: true)
        let controller = makeController(store)
        let id = UUID()
        _ = try await controller.admit(connectionID: id,
            identity: makeIdentity(), lifecycle: 1, publicationSuppressed: false, policy: .init(maximumConnectionsPerDevice: 2, maximumConnectionsPerUser: 8))
        let before = await controller.snapshot(connectionID: id).deadline
        #expect(!(await controller.refreshProjection(connectionID: id, lifecycle: 1)))
        #expect(await controller.snapshot(connectionID: id).deadline == before)
        await controller.finish()
    }

    @Test("an expired online projection repairs under the original policy without granting socket authority")
    func expiredProjectionCanRecoverWithoutReauthentication() async throws {
        let store = ControllerLeaseStore(rejectRenewal: true, leaseSeconds: 0.03)
        let controller = makeController(store)
        let id = UUID(), identity = makeIdentity()
        let policy = V2AuthenticatedConnectionAdmissionPolicy(maximumConnectionsPerDevice: 2, maximumConnectionsPerUser: 8)
        _ = try await controller.admit(connectionID: id, identity: identity, lifecycle: 1,
            publicationSuppressed: true, policy: policy)
        let expiry = try #require(await controller.snapshot(connectionID: id).deadline)
        try await ContinuousClock().sleep(until: expiry + .milliseconds(1))
        #expect(await controller.refreshProjection(connectionID: id, lifecycle: 1))
        #expect(await controller.heartbeat(connectionID: id, lifecycle: 1))
        #expect(await controller.snapshot(connectionID: id).deadline.map { $0 > .now } == true)
        #expect(await store.admissionPolicies == [policy, policy])
        #expect(await store.publicationSuppression == [true, true])
        await controller.revoke(connectionID: id, lifecycle: 1)
        #expect(!(await controller.heartbeat(connectionID: id, lifecycle: 1)))
        await controller.finish()
    }

    @Test("cancelled callers cannot release SQL ownership or resurrect revoked leases")
    func actualRenewalDrainsBeforeRemoval() async throws {
        let store = ControllerLeaseStore(blockRenewal: true)
        let controller = makeController(store)
        let id = UUID(), identity = makeIdentity()
        _ = try await controller.admit(connectionID: id,
            identity: identity, lifecycle: 1, publicationSuppressed: false, policy: .init(maximumConnectionsPerDevice: 2, maximumConnectionsPerUser: 8))
        let request = Task { await controller.refreshProjection(connectionID: id, lifecycle: 1) }
        await store.waitForRenewal()
        request.cancel()
        await controller.revoke(connectionID: id, lifecycle: 1)
        #expect(await controller.snapshot(connectionID: id).deadline == nil)
        let replacement = try await controller.admit(connectionID: id,
            identity: identity, lifecycle: 2, publicationSuppressed: false, policy: .init(maximumConnectionsPerDevice: 2, maximumConnectionsPerUser: 8))
        #expect(replacement == nil)
        // Initiating close must return before the actual renewal is unblocked.
        #expect(await controller.removePresence(identity: identity, connectionID: id) == nil)
        await store.releaseRenewal()
        #expect(!(await request.value))
        await controller.finish()
        #expect(await store.removalCount == 1)
        #expect(await controller.snapshot(connectionID: id).deadline == nil)
    }

    @Test("close returns while admission SQL is pending, then owned cleanup drains")
    func lateAdmissionCleanupDoesNotBlockRevocation() async throws {
        let store = ControllerLeaseStore(blockAdmission: true)
        let controller = makeController(store)
        let id = UUID(), identity = makeIdentity()
        let admission = Task {
            try await controller.admit(connectionID: id,
                identity: identity, lifecycle: 1, publicationSuppressed: false,
                policy: .init(maximumConnectionsPerDevice: 2, maximumConnectionsPerUser: 8))
        }
        await store.waitForAdmission()
        await controller.revoke(connectionID: id, lifecycle: 1)
        #expect(await controller.removePresence(identity: identity, connectionID: id) == nil)
        // SQL is intentionally released only AFTER initiating close, matching a
        // socket owner that cannot wait for a database response to revoke itself.
        let successor = try await controller.admit(connectionID: id,
            identity: identity, lifecycle: 2, publicationSuppressed: false,
            policy: .init(maximumConnectionsPerDevice: 2, maximumConnectionsPerUser: 8))
        #expect(successor == nil)
        await store.releaseAdmission()
        #expect(try await admission.value == nil)
        await controller.finish()
        #expect(await store.removalCount >= 1)
        #expect(await controller.snapshot(connectionID: id).deadline == nil)
    }

    @Test("a blocked admission does not prevent another connection's eligible cleanup")
    func eligibleCleanupSkipsBlockedAdmission() async throws {
        let store = ControllerLeaseStore(blockRenewal: true, blockAdmission: true)
        let controller = makeController(store)
        let first = UUID(), second = UUID(), identity = makeIdentity()
        let admission = Task {
            try await controller.admit(connectionID: first,
                identity: identity, lifecycle: 1, publicationSuppressed: false,
                policy: .init(maximumConnectionsPerDevice: 2, maximumConnectionsPerUser: 8))
        }
        await store.waitForAdmission()
        await controller.revoke(connectionID: first, lifecycle: 1)
        #expect(await controller.removePresence(identity: identity, connectionID: first) == nil)
        _ = try await controller.admit(connectionID: second,
            identity: identity, lifecycle: 2, publicationSuppressed: false,
            policy: .init(maximumConnectionsPerDevice: 2, maximumConnectionsPerUser: 8))
        let renewal = Task { await controller.refreshProjection(connectionID: second, lifecycle: 2) }
        await store.waitForRenewal()
        await controller.revoke(connectionID: second, lifecycle: 2)
        #expect(await controller.removePresence(identity: identity, connectionID: second) == nil)
        await store.releaseRenewal()
        #expect(!(await renewal.value))
        await store.waitForRemoval()
        // The first admission remains gated. Its unready cleanup must not
        // occupy the single cleanup worker ahead of the second connection.
        #expect(await store.removedIDs == [second])
        await store.releaseAdmission()
        #expect(try await admission.value == nil)
        await controller.finish()
    }

    @Test("publication SQL retains its old lifecycle through cancellation and close")
    func latePublicationCannotTouchSuccessor() async throws {
        let store = ControllerLeaseStore(blockPublication: true)
        let controller = makeController(store)
        let id = UUID(), identity = makeIdentity()
        _ = try await controller.admit(connectionID: id,
            identity: identity, lifecycle: 1, publicationSuppressed: false,
            policy: .init(maximumConnectionsPerDevice: 2, maximumConnectionsPerUser: 8))
        let policy = Task {
            try await controller.setPresencePublication(connectionID: id, lifecycle: 1,
                identity: identity, suppressed: true)
        }
        await store.waitForPublication()
        policy.cancel()
        await controller.revoke(connectionID: id, lifecycle: 1)
        #expect(await controller.removePresence(identity: identity, connectionID: id) == nil)
        let successor = try await controller.admit(connectionID: id,
            identity: identity, lifecycle: 2, publicationSuppressed: false,
            policy: .init(maximumConnectionsPerDevice: 2, maximumConnectionsPerUser: 8))
        #expect(successor == nil)
        await store.releasePublication()
        #expect(try await policy.value == nil)
        await controller.finish()
        #expect(await store.publicationCount == 1)
        #expect(await store.removalCount == 1)
    }

    @Test("concurrent authoritative renewals share one actual database waiter")
    func projectionRefreshesAreSingleFlight() async throws {
        let store = ControllerLeaseStore(blockRenewal: true)
        let controller = makeController(store)
        let id = UUID(), identity = makeIdentity()
        _ = try await controller.admit(connectionID: id,
            identity: identity, lifecycle: 1, publicationSuppressed: false,
            policy: .init(maximumConnectionsPerDevice: 2, maximumConnectionsPerUser: 8))
        let first = Task { await controller.refreshProjection(connectionID: id, lifecycle: 1) }
        await store.waitForRenewal()
        let others = (0..<4).map { _ in Task { await controller.refreshProjection(connectionID: id, lifecycle: 1) } }
        let bound = ContinuousClock.now + .seconds(2)
        while await controller.projectionRefreshWaiterCount(connectionID: id) < 5 {
            guard ContinuousClock.now < bound else { throw CancellationError() }
            await Task.yield()
        }
        first.cancel()
        #expect(await controller.metrics().submittedRequests == 1)
        #expect(await controller.snapshot(connectionID: id).renewing)
        await store.releaseRenewal()
        #expect(await first.value)
        for task in others { #expect(await task.value) }
        #expect(await store.renewalCount == 1)
        await controller.finish()
    }

    private func makeController(_ store: ControllerLeaseStore) -> V2ConnectionLeaseController {
        .init(leases: store, configuration: .init(maximumBatchSize: 1, maximumDelay: .zero),
            maximumConnections: 4)
    }
    private func makeIdentity() -> V2AuthenticatedConnection {
        .init(userID: .init(uuid: UUID()), deviceID: .init(uuid: UUID()), capabilityProfile: "base")
    }
}

private actor ControllerLeaseStore: V2LivePresenceLeaseManaging {
    func admitConnectionRefresh(identity: V2AuthenticatedConnection, connectionID: UUID,
        publicationSuppressed: Bool, policy: V2AuthenticatedConnectionAdmissionPolicy, now: Date) async throws -> V2LivePresenceLeaseRefresh {
        try await v2FixtureAdmitConnectionRefresh(store: self, identity: identity, connectionID: connectionID,
            publicationSuppressed: publicationSuppressed, policy: policy, now: now)
    }

    let failRenewal: Bool
    let rejectRenewal: Bool
    let leaseSeconds: TimeInterval
    private(set) var admissionPolicies: [V2AuthenticatedConnectionAdmissionPolicy] = []
    private(set) var publicationSuppression: [Bool] = []
    var blockRenewal: Bool
    var blockAdmission: Bool
    var blockPublication: Bool
    private(set) var publicationCount = 0
    private var publicationGate: CheckedContinuation<Void, Never>?
    private var publicationWaiter: CheckedContinuation<Void, Never>?
    private var admissionBegan = false
    private var admissionGate: CheckedContinuation<Void, Never>?
    private var admissionWaiter: CheckedContinuation<Void, Never>?
    private(set) var renewalCount = 0
    private(set) var removalCount = 0
    private(set) var removedIDs: [UUID] = []
    private var removalWaiter: CheckedContinuation<Void, Never>?
    private var gate: CheckedContinuation<Void, Never>?
    private var startedWaiter: CheckedContinuation<Void, Never>?
    init(failRenewal: Bool = false, rejectRenewal: Bool = false, leaseSeconds: TimeInterval = 90, blockRenewal: Bool = false, blockAdmission: Bool = false, blockPublication: Bool = false) {
        self.failRenewal = failRenewal; self.rejectRenewal = rejectRenewal; self.leaseSeconds = leaseSeconds; self.blockRenewal = blockRenewal; self.blockAdmission = blockAdmission; self.blockPublication = blockPublication
    }
    func admitConnection(identity: V2AuthenticatedConnection, connectionID: UUID,
        publicationSuppressed: Bool, policy: V2AuthenticatedConnectionAdmissionPolicy,
        now: Date) async -> V2AuthenticatedConnectionLeaseOutcome {
        admissionPolicies.append(policy); publicationSuppression.append(publicationSuppressed)
        let shouldBlock = blockAdmission && !admissionBegan
        admissionBegan = true; admissionWaiter?.resume(); admissionWaiter = nil
        if shouldBlock { await withCheckedContinuation { admissionGate = $0 } }
        return .accepted(expiresAt: now.addingTimeInterval(leaseSeconds))
    }
    func waitForAdmission() async {
        if admissionBegan { return }
        await withCheckedContinuation { admissionWaiter = $0 }
    }
    func releaseAdmission() { blockAdmission = false; admissionGate?.resume(); admissionGate = nil }
    func renewConnection(identity: V2AuthenticatedConnection, connectionID: UUID,
        now: Date) async -> V2AuthenticatedConnectionLeaseOutcome {
        let shouldBlock = blockAdmission && !admissionBegan
        admissionBegan = true; admissionWaiter?.resume(); admissionWaiter = nil
        if shouldBlock { await withCheckedContinuation { admissionGate = $0 } }
        return .accepted(expiresAt: now.addingTimeInterval(leaseSeconds))
    }
    func renewConnections(_ requests: [V2LivePresenceLeaseRenewalRequest]) async throws -> [UUID: V2LivePresenceLeaseRefresh] {
        renewalCount += 1
        startedWaiter?.resume(); startedWaiter = nil
        if blockRenewal { await withCheckedContinuation { gate = $0 } }
        if failRenewal { throw CancellationError() }
        return Dictionary(uniqueKeysWithValues: requests.map {
            ($0.connectionID, .init(outcome: rejectRenewal ? .rejected : .accepted(expiresAt: $0.now.addingTimeInterval(leaseSeconds)), allowsOnlinePresence: true))
        })
    }
    func removePresence(identity: V2AuthenticatedConnection, connectionID: UUID, now: Date) -> Bool {
        removalCount += 1; removedIDs.append(connectionID)
        removalWaiter?.resume(); removalWaiter = nil
        return false
    }
    func waitForRemoval() async {
        if removalCount > 0 { return }
        await withCheckedContinuation { removalWaiter = $0 }
    }
    func allowsOnlinePresence(userID: UserID) -> Bool { true }
    func setPresencePublication(identity: V2AuthenticatedConnection, connectionID: UUID,
        suppressed: Bool, now: Date) async -> V2PresencePublicationLeaseObservation {
        publicationCount += 1; publicationWaiter?.resume(); publicationWaiter = nil
        if blockPublication { await withCheckedContinuation { publicationGate = $0 } }
        return .init(isOnline: !suppressed, expiresAt: now.addingTimeInterval(90))
    }
    func waitForPublication() async {
        if publicationCount > 0 { return }
        await withCheckedContinuation { publicationWaiter = $0 }
    }
    func releasePublication() { blockPublication = false; publicationGate?.resume(); publicationGate = nil }
    func waitForRenewal() async {
        if renewalCount > 0 { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }
    func releaseRenewal() { blockRenewal = false; gate?.resume(); gate = nil }
}
