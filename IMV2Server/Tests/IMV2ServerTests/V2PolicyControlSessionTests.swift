import Foundation
import Synchronization
import Testing
import IMV2ActorContracts
@testable import IMV2ServerApplication
@testable import IMV2ServerInfrastructure

@Suite("Policy control sessions", .timeLimit(.minutes(1)))
struct V2PolicyControlSessionTests {
    private let source = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
    private let recipient = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
    private func snapshot(_ scope: V2PolicyAuthorizationScope, version: Int64 = 1, active: Bool = true) throws -> V2PolicyFactsSnapshot {
        guard case .account(let user) = scope else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
        return try .init(scope: scope, version: version, facts: .account(.init(userID: user, isActive: active,
            specialKind: nil, specialStatus: nil, allowsServiceMessages: nil, allowsCustomerMessages: nil)))
    }
    @Test("expired generation rejects late heartbeats and snapshots; new generation cannot revive other scopes")
    func expiredGenerationNeedsFreshSnapshots() async throws {
        let clock = Mutex(ContinuousClock.now)
        let cache = V2NodePolicyStateCache(identity: recipient, now: { clock.withLock { $0 } })
        let first = V2PolicyAuthorizationScope.account(UUID()), second = V2PolicyAuthorizationScope.account(UUID())
        let old = try V2PolicyControlSessionWire(source: source, recipient: recipient, generation: 1)
        try await cache.prepareRemoteScopes([first, second], source: source)
        try await cache.installRemoteBatch(.init(session: old, snapshots: [snapshot(first).wire, snapshot(second).wire]), source: source)
        #expect(try await cache.cachedSnapshots(scopes: [first, second])?.count == 2)
        clock.withLock { $0 += .seconds(11) }
        #expect(try await cache.cachedSnapshots(scopes: [first]) == nil)
        await #expect(throws: V2PolicyAuthorizationLifecycleError.ownerChanged) {
            try await cache.applyControl(.init(endpoint: "gateway", session: old, sequence: 3, payload: .heartbeat))
        }
        await #expect(throws: V2PolicyAuthorizationLifecycleError.ownerChanged) {
            try await cache.installRemoteBatch(.init(session: old, snapshots: [snapshot(first).wire]), source: source)
        }
        let fresh = try V2PolicyControlSessionWire(source: source, recipient: recipient, generation: 2)
        try await cache.installRemoteBatch(.init(session: fresh, snapshots: [snapshot(first, version: 2, active: false).wire]), source: source)
        #expect(try await cache.cachedSnapshots(scopes: [first])?.first?.version == 2)
        #expect(try await cache.cachedSnapshots(scopes: [second]) == nil)
        await #expect(throws: V2PolicyAuthorizationLifecycleError.ownerChanged) {
            try await cache.applyControl(.init(endpoint: "gateway", session: old, sequence: 4, payload: .retire))
        }
        #expect(try await cache.cachedSnapshots(scopes: [first]) != nil)
        await cache.shutdown()
    }
    @Test("owner incarnation replacement invalidates every old scope and rejects its delayed reply")
    func newSourceIncarnationRejectsLateOldReply() async throws {
        let cache = V2NodePolicyStateCache(identity: recipient)
        let first = V2PolicyAuthorizationScope.account(UUID()), second = V2PolicyAuthorizationScope.account(UUID())
        let old = try V2PolicyControlSessionWire(source: source, recipient: recipient, generation: 1)
        try await cache.prepareRemoteScopes([first, second], source: source)
        try await cache.installRemoteBatch(.init(session: old, snapshots: [snapshot(first).wire, snapshot(second).wire]), source: source)
        let moved = V2ActorHostIdentity(hostID: source.hostID, incarnationID: UUID())
        let revision = try await cache.prepareRemoteScopes([first], source: moved)
        #expect(try await cache.cachedSnapshots(scopes: [second]) == nil)
        await #expect(throws: V2PolicyAuthorizationLifecycleError.invalidTarget) {
            try await cache.installRemoteBatch(.init(session: old, snapshots: [snapshot(second).wire]), source: source)
        }
        let fresh = try V2PolicyControlSessionWire(source: moved, recipient: recipient, generation: 1)
        try await cache.installRemoteBatch(.init(session: fresh, snapshots: [snapshot(first, version: 2).wire], interestRevision: revision), source: moved)
        #expect(try await cache.cachedSnapshots(scopes: [first])?.first?.version == 2)
        await cache.shutdown()
    }
    @Test("a committed push wins the older reply of an initializing remote reader")
    func pushWinsInitializingReply() async throws {
        let cache = V2NodePolicyStateCache(identity: recipient), gate = PolicyControlTestGate()
        let scope = V2PolicyAuthorizationScope.account(UUID())
        let session = try V2PolicyControlSessionWire(source: source, recipient: recipient, generation: 1)
        let old = try snapshot(scope), fresh = try snapshot(scope, version: 2, active: false)
        let load = Task {
            try await cache.loadSnapshots(scopes: [scope]) { scopes in
                try await cache.prepareRemoteScopes(scopes, source: source)
                await gate.hold()
                try await cache.installRemoteBatch(.init(session: session, snapshots: [old.wire]), source: source)
                return [old]
            }
        }
        await gate.waitUntilEntered()
        try await cache.applyControl(.init(endpoint: "gateway", session: session, sequence: 1, payload: .snapshot(fresh.wire)))
        await gate.release()
        #expect(try await load.value == [fresh])
        await cache.shutdown()
    }
    @Test("failure retires cached authority; retry sends retained facts on a new generation")
    func failedPushRetainsFactsAndClosesAuthority() async throws {
        enum Failure: Error { case unavailable }
        let cache = V2NodePolicyStateCache(identity: recipient), fail = Mutex(true)
        let target = try V2PolicySnapshotSubscriberWire(host: recipient, endpoint: "gateway")
        let publisher = V2PolicySnapshotPublisher(targets: [try .init(hostID: recipient.hostID, endpoint: "gateway")],
            identity: source, cache: V2NodePolicyStateCache(), validateRecipient: { _ in }, send: { update, _ in
                if case .snapshot = update.payload, fail.withLock({ value in let fail = value; value = false; return fail }) {
                    throw Failure.unavailable
                }
                try await cache.applyControl(update)
            })
        let scope = V2PolicyAuthorizationScope.account(UUID())
        let old = try await publisher.subscribe(scopes: [scope], target: target)
        try await publisher.confirmRegistration(old)
        try await cache.prepareRemoteScopes([scope], source: source)
        try await cache.installRemoteBatch(.init(session: old, snapshots: [snapshot(scope).wire]), source: source)
        let fresh = try snapshot(scope, version: 2, active: false)
        await #expect(throws: Failure.unavailable) { try await publisher.publish(fresh) }
        #expect(try await cache.cachedSnapshots(scopes: [scope]) == nil)
        try await publisher.publish(fresh)
        #expect(try await cache.cachedSnapshots(scopes: [scope]) == [fresh])
        let successor = try await publisher.subscribe(scopes: [scope], target: target)
        #expect(successor.generation > old.generation)
        await #expect(throws: V2PolicyAuthorizationLifecycleError.ownerChanged) {
            try await cache.applyControl(.init(endpoint: "gateway", session: old, sequence: 20, payload: .heartbeat))
        }
        await publisher.shutdown()
        #expect(try await cache.cachedSnapshots(scopes: [scope]) == nil)
        await cache.shutdown()
    }
    @Test("unacknowledged control work prevents heartbeat from keeping old permissions alive")
    func stalledControlStopsHeartbeat() async throws {
        let clock = Mutex(ContinuousClock.now), pulses = Mutex(0), gate = PolicyControlTestGate()
        let cache = V2NodePolicyStateCache(identity: recipient, now: { clock.withLock { $0 } })
        let target = try V2PolicySnapshotSubscriberWire(host: recipient, endpoint: "gateway")
        let publisher = V2PolicySnapshotPublisher(targets: [try .init(hostID: recipient.hostID, endpoint: "gateway")],
            identity: source, cache: V2NodePolicyStateCache(), validateRecipient: { _ in }, send: { update, _ in
                if case .snapshot = update.payload { await gate.hold() }
                if case .heartbeat = update.payload { pulses.withLock { $0 += 1 } }
                try await cache.applyControl(update)
            })
        let scope = V2PolicyAuthorizationScope.account(UUID())
        let session = try await publisher.subscribe(scopes: [scope], target: target)
        try await publisher.confirmRegistration(session)
        try await cache.prepareRemoteScopes([scope], source: source)
        try await cache.installRemoteBatch(.init(session: session, snapshots: [snapshot(scope).wire]), source: source)
        try await publisher.start(qualified: { true })
        let value = try snapshot(scope, version: 2, active: false)
        let mutation = Task { try await publisher.publish(value) }
        await gate.waitUntilEntered()
        try await Task.sleep(for: .milliseconds(2200))
        #expect(pulses.withLock { $0 } == 0)
        clock.withLock { $0 += .seconds(11) }
        #expect(try await cache.cachedSnapshots(scopes: [scope]) == nil)
        await gate.release()
        await #expect(throws: V2PolicyAuthorizationLifecycleError.ownerChanged) { try await mutation.value }
        await publisher.shutdown(); await cache.shutdown()
    }

    @Test("a change blocks heartbeat before persistence starts; an uncertain result retires authority")
    func pendingMutationBlocksHeartbeat() async throws {
        let pulses = Mutex(0), cache = V2NodePolicyStateCache(identity: recipient)
        let local = V2NodePolicyStateCache()
        let target = try V2PolicySnapshotSubscriberWire(host: recipient, endpoint: "gateway")
        let publisher = V2PolicySnapshotPublisher(targets: [try .init(hostID: recipient.hostID, endpoint: "gateway")],
            identity: source, cache: local, validateRecipient: { _ in }, send: { update, _ in
                if case .heartbeat = update.payload { pulses.withLock { $0 += 1 } }
                try await cache.applyControl(update)
            })
        let scope = V2PolicyAuthorizationScope.account(UUID()), initial = try snapshot(scope)
        try await local.install(initial)
        let session = try await publisher.subscribe(scopes: [scope], target: target)
        try await publisher.confirmRegistration(session)
        try await cache.prepareRemoteScopes([scope], source: source)
        try await cache.installRemoteBatch(.init(session: session, snapshots: [initial.wire]), source: source)
        try await publisher.beginChange(scope)
        try await publisher.start(qualified: { true })
        try await Task.sleep(for: .milliseconds(2200))
        #expect(pulses.withLock { $0 } == 0)
        await publisher.finishChange(scope, succeeded: false)
        #expect(try await cache.cachedSnapshots(scopes: [scope]) == nil)
        #expect(try await local.cachedSnapshots(scopes: [scope]) == nil)
        let fresh = try await publisher.subscribe(scopes: [scope], target: target)
        #expect(fresh.generation > session.generation)
        await publisher.shutdown(); await cache.shutdown(); await local.shutdown()
    }

    @Test("an invalidated cold read cannot install its delayed response")
    func invalidatedFlightRejectsDelayedReply() async throws {
        let cache = V2NodePolicyStateCache(identity: recipient), gate = PolicyControlTestGate()
        let scope = V2PolicyAuthorizationScope.account(UUID()), initial = try snapshot(scope)
        let session = try V2PolicyControlSessionWire(source: source, recipient: recipient, generation: 1)
        let load = Task {
            try await cache.loadSnapshots(scopes: [scope]) { scopes in
                try await cache.prepareRemoteScopes(scopes, source: source)
                await gate.hold()
                try await cache.installRemoteBatch(.init(session: session, snapshots: [initial.wire]), source: source)
                return [initial]
            }
        }
        await gate.waitUntilEntered()
        await cache.invalidate(scope)
        await gate.release()
        await #expect(throws: V2PolicyAuthorizationLifecycleError.ownerChanged) { try await load.value }
        #expect(try await cache.cachedSnapshots(scopes: [scope]) == nil)
        let fresh = try snapshot(scope, version: 2, active: false)
        let recovered = try await cache.loadSnapshots(scopes: [scope]) { scopes in
            let revision = try await cache.prepareRemoteScopes(scopes, source: source)
            try await cache.installRemoteBatch(.init(session: .init(source: source, recipient: recipient, generation: 2),
                snapshots: [fresh.wire], interestRevision: revision), source: source)
            return [fresh]
        }
        #expect(recovered == [fresh])
        await cache.shutdown()
    }

    @Test("an unverified recipient incarnation cannot supersede a registered node")
    func unverifiedRecipientCannotReplaceSession() async throws {
        let expected = recipient
        let target = try V2PolicySnapshotSubscriberWire(host: expected, endpoint: "gateway")
        let local = V2NodePolicyStateCache()
        let publisher = V2PolicySnapshotPublisher(targets: [try .init(hostID: expected.hostID, endpoint: "gateway")],
            identity: source, cache: local, validateRecipient: { candidate in
                guard candidate.host == expected else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
            }, send: { _, _ in })
        let scope = V2PolicyAuthorizationScope.account(UUID())
        let current = try await publisher.subscribe(scopes: [scope], target: target)
        let impostor = try V2PolicySnapshotSubscriberWire(host: .init(hostID: expected.hostID, incarnationID: UUID()), endpoint: "gateway")
        await #expect(throws: V2PolicyAuthorizationLifecycleError.invalidTarget) {
            try await publisher.subscribe(scopes: [scope], target: impostor)
        }
        #expect(try await publisher.subscribe(scopes: [scope], target: target) == current)
        await publisher.shutdown(); await local.shutdown()
    }

    @Test("a delayed interest release preserves a newer registration and stale registrations cannot return")
    func releaseDoesNotDeleteReloadedInterest() async throws {
        let target = try V2PolicySnapshotSubscriberWire(host: recipient, endpoint: "gateway")
        let delivered = Mutex<[V2PolicySnapshotUpdateWire]>([]), local = V2NodePolicyStateCache()
        let publisher = V2PolicySnapshotPublisher(targets: [try .init(hostID: recipient.hostID, endpoint: target.endpoint)],
            identity: source, cache: local, validateRecipient: { _ in }, send: { update, _ in delivered.withLock { $0.append(update) } })
        let scope = V2PolicyAuthorizationScope.account(UUID())
        let original = try await publisher.subscribe(scopes: [scope], target: target, interestRevision: 1)
        try await publisher.confirmRegistration(original)
        _ = try await publisher.subscribe(scopes: [scope], target: target, interestRevision: 2)
        try await publisher.release(.init(endpoint: "policy", source: source, subscriber: target,
            payload: .scopes([.init(scope: scope.policyWire, revision: 1)])))
        try await publisher.publish(snapshot(scope, version: 2, active: false))
        #expect(delivered.withLock { $0.contains { if case .snapshot(let wire) = $0.payload { return wire.version == 2 }; return false } })
        try await publisher.release(.init(endpoint: "policy", source: source, subscriber: target,
            payload: .scopes([.init(scope: scope.policyWire, revision: 2)])))
        let count = delivered.withLock { $0.count }
        try await publisher.publish(snapshot(scope, version: 3))
        #expect(delivered.withLock { $0.count } == count)
        await #expect(throws: V2PolicyAuthorizationLifecycleError.ownerChanged) {
            try await publisher.subscribe(scopes: [scope], target: target, interestRevision: 1)
        }
        let fresh = try await publisher.subscribe(scopes: [scope], target: target, interestRevision: 3)
        #expect(fresh.generation > original.generation)
        await publisher.shutdown(); await local.shutdown()
    }

    @Test("LRU eviction asynchronously releases its exact remote interest without blocking a reload")
    func evictionReleasesExactRegistration() async throws {
        let gate = PolicyControlTestGate(), releases = Mutex<[V2PolicyInterestReleaseWire]>([])
        let target = try V2PolicySnapshotSubscriberWire(host: recipient, endpoint: "gateway")
        let cache = V2NodePolicyStateCache(maximumEntries: 1, identity: recipient, subscriber: target,
            releaseInterests: { request in
                await gate.hold()
                releases.withLock { $0.append(request) }
            })
        await cache.startInterestReleases()
        let first = V2PolicyAuthorizationScope.account(UUID()), second = V2PolicyAuthorizationScope.account(UUID())
        let session = try V2PolicyControlSessionWire(source: source, recipient: recipient, generation: 1)
        let revision = try await cache.prepareRemoteScopes([first], source: source)
        try await cache.installRemoteBatch(.init(session: session, snapshots: [snapshot(first).wire], interestRevision: revision), source: source)
        let secondRevision = try await cache.prepareRemoteScopes([second], source: source)
        try await cache.installRemoteBatch(.init(session: session, snapshots: [snapshot(second).wire], interestRevision: secondRevision), source: source)
        await gate.waitUntilEntered()
        let reloaded = try await cache.prepareRemoteScopes([first], source: source)
        #expect(reloaded > revision)
        try await cache.installRemoteBatch(.init(session: session, snapshots: [snapshot(first).wire], interestRevision: reloaded), source: source)
        #expect(try await cache.cachedSnapshots(scopes: [first]) != nil)
        await gate.release()
        let deadline = ContinuousClock.now + .seconds(3)
        while releases.withLock({ $0.isEmpty }) {
            try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(1))
        }
        let firstRelease = try #require(releases.withLock { $0.first })
        guard case .scopes(let items) = firstRelease.payload else { Issue.record("expected an exact release"); await cache.shutdown(); return }
        #expect(items.contains { $0.scope.key == first.key && $0.revision == revision })
        #expect(try await cache.cachedSnapshots(scopes: [first]) != nil)
        await cache.shutdown()
    }

    @Test("release-buffer overflow replaces cleanup with a bounded reset and closes cached authority")
    func releaseOverflowClosesSourceAuthority() async throws {
        let sent = Mutex<[V2PolicyInterestReleaseWire]>([])
        let target = try V2PolicySnapshotSubscriberWire(host: recipient, endpoint: "gateway")
        let cache = V2NodePolicyStateCache(maximumEntries: 1, identity: recipient, subscriber: target,
            releaseInterests: { request in sent.withLock { $0.append(request) } }, maximumPendingReleases: 1)
        let session = try V2PolicyControlSessionWire(source: source, recipient: recipient, generation: 1)
        let scopes = (0..<3).map { _ in V2PolicyAuthorizationScope.account(UUID()) }
        for scope in scopes.prefix(2) {
            let revision = try await cache.prepareRemoteScopes([scope], source: source)
            try await cache.installRemoteBatch(.init(session: session, snapshots: [snapshot(scope).wire], interestRevision: revision), source: source)
        }
        let thirdRevision = try await cache.prepareRemoteScopes([scopes[2]], source: source)
        await #expect(throws: V2PolicyAuthorizationLifecycleError.ownerChanged) {
            try await cache.installRemoteBatch(.init(session: session, snapshots: [snapshot(scopes[2]).wire], interestRevision: thirdRevision), source: source)
        }
        #expect(try await cache.cachedSnapshots(scopes: [scopes[2]]) == nil)
        await cache.startInterestReleases()
        let deadline = ContinuousClock.now + .seconds(3)
        while sent.withLock({ $0.isEmpty }) {
            try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(1))
        }
        #expect(sent.withLock { $0.contains { if case .reset(let cut, _) = $0.payload { return cut == thirdRevision }; return false } })
        await cache.shutdown()
    }

    @Test("cache shutdown releases its remote registrations and stops further source publication")
    func shutdownReleasesRemoteInterests() async throws {
        let target = try V2PolicySnapshotSubscriberWire(host: recipient, endpoint: "gateway")
        let binding = Mutex<V2PolicySnapshotPublisher?>(nil), sends = Mutex(0), local = V2NodePolicyStateCache()
        let cache = V2NodePolicyStateCache(identity: recipient, subscriber: target, releaseInterests: { request in
            guard let publisher = binding.withLock({ $0 }) else { throw V2PolicyAuthorizationLifecycleError.closed }
            try await publisher.release(request)
        })
        let publisher = V2PolicySnapshotPublisher(targets: [try .init(hostID: recipient.hostID, endpoint: target.endpoint)],
            identity: source, cache: local, validateRecipient: { _ in }, send: { update, _ in
                sends.withLock { $0 += 1 }; try await cache.applyControl(update)
            })
        binding.withLock { $0 = publisher }
        let scope = V2PolicyAuthorizationScope.account(UUID())
        let revision = try await cache.prepareRemoteScopes([scope], source: source)
        let session = try await publisher.subscribe(scopes: [scope], target: target, interestRevision: revision)
        try await publisher.confirmRegistration(session)
        try await cache.installRemoteBatch(.init(session: session, snapshots: [snapshot(scope).wire], interestRevision: revision), source: source)
        await cache.startInterestReleases(); await cache.shutdown()
        let afterShutdown = sends.withLock { $0 }
        try await publisher.publish(snapshot(scope, version: 2, active: false))
        #expect(sends.withLock { $0 } == afterShutdown)
        await #expect(throws: V2PolicyAuthorizationLifecycleError.ownerChanged) {
            try await publisher.subscribe(scopes: [scope], target: target, interestRevision: revision)
        }
        await publisher.shutdown(); await local.shutdown(); binding.withLock { $0 = nil }
    }
}
private actor PolicyControlTestGate {
    private var entered = false
    private var released = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var blocked: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true; enteredWaiter?.resume(); enteredWaiter = nil
        if !released { await withCheckedContinuation { blocked = $0 } }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { enteredWaiter = $0 } }
    }
    func release() { released = true; blocked?.resume(); blocked = nil }
}
