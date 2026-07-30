import Foundation
import IMV2Core

/// Delivery means a durable, idempotent user-sync projection. Socket or push
/// wake-ups are downstream hints and cannot decide whether a fan-out target is
/// considered delivered.
public struct V2FanoutDeliveryLease: Equatable, Sendable {
    public let sourceEventID: EventID
    public let targetUserID: UserID
    public let projectionKind: String
    public let completionUnitID: CompletionUnitID
    public let observedRoute: V2UserShardRoute
    public let claimToken: UUID
    public let attempt: Int
    /// A process-local copy of the immutable source event payload. It is
    /// populated only by the cross-store claim path to avoid a second control
    /// database round-trip before the target projection. The durable lease
    /// fence remains the claim token; this value is never persisted as lease
    /// state and callers without it use the fenced control-store read.
    public let eventPayloadJSON: String?

    public init(sourceEventID: EventID, targetUserID: UserID, projectionKind: String, completionUnitID: CompletionUnitID, observedRoute: V2UserShardRoute, claimToken: UUID, attempt: Int = 1, eventPayloadJSON: String? = nil) {
        precondition(attempt > 0)
        self.sourceEventID = sourceEventID
        self.targetUserID = targetUserID
        self.projectionKind = projectionKind
        self.completionUnitID = completionUnitID
        self.observedRoute = observedRoute
        self.claimToken = claimToken
        self.attempt = attempt
        self.eventPayloadJSON = eventPayloadJSON
    }
}

public enum V2FanoutDeliveryCommit: Equatable, Sendable {
    case staleLease
    case committed(userSyncSequence: UInt64, releasedCompletionUnit: Bool, closedPlan: Bool)
}

/// A mutually exclusive class of durable delivery work. Keeping these classes
/// separate lets the hot path use an index that is specific to brand-new work,
/// without weakening retry, lease-expiry recovery, or the claim-token fence.
public enum V2FanoutDeliveryClaimLane: Sendable, Equatable {
    /// Never leased and never scheduled for a retry.
    case fresh
    /// Explicitly released after a failure and now due for another attempt.
    case retryDue
    /// A previous worker stopped making progress and its lease has elapsed.
    case expiredLease
}

public protocol V2FanoutDeliveryStore: Sendable {
    func claimPending(bucket: String?, lane: V2FanoutDeliveryClaimLane, now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2FanoutDeliveryLease]
    func commit(_ lease: V2FanoutDeliveryLease, now: Date) async throws -> V2FanoutDeliveryCommit
    /// Commits one bounded group of leases. Implementations that own all
    /// affected records in one database may make this one transaction; a
    /// cross-store implementation may retain per-lease commits because it
    /// cannot invent atomicity across physical databases.
    func commitBatch(_ leases: [V2FanoutDeliveryLease], now: Date) async throws -> [V2FanoutDeliveryCommit]
    /// Moves a claimed, not-yet-projected delivery to the router's current
    /// logical write bucket. Implementations must fence this update with the
    /// lease token; it is a handoff of one durable inbox effect, never a
    /// second delivery or a terminal skip.
    func handoff(_ lease: V2FanoutDeliveryLease, to route: V2UserShardRoute) async throws
    func release(_ lease: V2FanoutDeliveryLease) async throws
    func scheduleRetry(_ lease: V2FanoutDeliveryLease, disposition: V2DurableRetryDisposition, now: Date) async throws
}

/// Optional topology-specific cap for concurrent claim passes against one
/// logical bucket. The pipeline's global delivery concurrency is a capacity
/// ceiling, not permission to create contention within a single physical
/// target database. Stores that do not declare a cap retain the historical
/// concurrency behavior.
public protocol V2FanoutDeliveryBucketConcurrencyControlling: Sendable {
    var maximumConcurrentClaimsPerBucket: Int { get }
}

public extension V2FanoutDeliveryStore {
    /// Conservative fallback for fake and cross-store implementations. The
    /// concrete PostgreSQL control-store implementation overrides this with a
    /// bounded all-or-nothing transaction.
    func commitBatch(_ leases: [V2FanoutDeliveryLease], now: Date) async throws -> [V2FanoutDeliveryCommit] {
        var commits: [V2FanoutDeliveryCommit] = []
        commits.reserveCapacity(leases.count)
        for lease in leases {
            commits.append(try await commit(lease, now: now))
        }
        return commits
    }

    /// Compatibility helper for one-off administrative and integration-test
    /// callers. The runtime uses `V2FanoutDeliveryClaimScheduler` instead so
    /// a busy fresh lane cannot indefinitely postpone recovery work.
    func claimPending(bucket: String?, now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2FanoutDeliveryLease] {
        for lane in [.fresh, .retryDue, .expiredLease] as [V2FanoutDeliveryClaimLane] {
            let leases = try await claimPending(
                bucket: bucket, lane: lane, now: now, leaseDuration: leaseDuration, limit: limit
            )
            if !leases.isEmpty { return leases }
        }
        return []
    }

    /// Test/fake stores keep their immediate release semantics unless they
    /// opt in to durable PostgreSQL backoff and pause state.
    func scheduleRetry(_ lease: V2FanoutDeliveryLease, disposition _: V2DurableRetryDisposition, now _: Date) async throws {
        try await release(lease)
    }

    /// Legacy in-memory fakes may retain release-only behavior. The
    /// PostgreSQL implementation persists the new route before releasing the
    /// claim, which is required for an actual bucket cutover.
    func handoff(_ lease: V2FanoutDeliveryLease, to _: V2UserShardRoute) async throws {
        try await release(lease)
    }
}

/// Allocates claim turns for one logical target bucket. Seven (by default)
/// fast-path turns are followed by one recovery-first turn. If the preferred
/// lane is empty, a worker falls through to the other lanes immediately; if
/// it is busy, each turn still claims only one lane, retaining a bounded
/// transaction and its all-or-nothing lease update.
public actor V2FanoutDeliveryClaimScheduler {
    private let freshBurstPasses: Int
    private var freshPassesSinceRecovery = 0
    private var nextRecoveryLane: V2FanoutDeliveryClaimLane = .retryDue

    public init(freshBurstPasses: Int = 7) {
        precondition(freshBurstPasses > 0)
        self.freshBurstPasses = freshBurstPasses
    }

    public func lanesForNextClaim() -> [V2FanoutDeliveryClaimLane] {
        if freshPassesSinceRecovery < freshBurstPasses {
            freshPassesSinceRecovery += 1
            return [.fresh, nextRecoveryLane, alternateRecoveryLane]
        }

        freshPassesSinceRecovery = 0
        let recoveryLane = nextRecoveryLane
        let otherRecoveryLane = alternateRecoveryLane
        nextRecoveryLane = otherRecoveryLane
        return [recoveryLane, otherRecoveryLane, .fresh]
    }

    private var alternateRecoveryLane: V2FanoutDeliveryClaimLane {
        nextRecoveryLane == .retryDue ? .expiredLease : .retryDue
    }
}

public protocol V2LiveSyncNotifier: Sendable {
    func notifySyncAvailable(userID: UserID, eventID: UInt64, highWatermark: UInt64) async
}

public struct V2FanoutDeliveryReport: Equatable, Sendable {
    public let claimedCount: Int
    public let committedCount: Int
    public let staleCount: Int
    public let staleRouteCount: Int
    public let releasedCount: Int
    public let pausedCount: Int

    public init(claimedCount: Int, committedCount: Int, staleCount: Int, staleRouteCount: Int = 0, releasedCount: Int, pausedCount: Int = 0) {
        self.claimedCount = claimedCount
        self.committedCount = committedCount
        self.staleCount = staleCount
        self.staleRouteCount = staleRouteCount
        self.releasedCount = releasedCount
        self.pausedCount = pausedCount
    }
}

/// A bounded caller-scheduled worker. It purposely processes sequentially:
/// database lease contention is the backpressure boundary, while deployment
/// controls parallelism through bucket ownership and worker replicas.
public struct V2FanoutDeliveryWorker: Sendable {
    private let store: any V2FanoutDeliveryStore
    private let bucket: String?
    private let leaseDuration: TimeInterval
    private let now: @Sendable () -> Date
    private let liveNotifier: (any V2LiveSyncNotifier)?
    private let router: (any V2UserShardRouter)?
    private let retryPolicy: V2DurableRetryPolicy
    private let claimScheduler: V2FanoutDeliveryClaimScheduler
    private let commitBatchSize: Int
    /// Normally one: a durable batch's complete target/control protocol stays
    /// sequential unless the remote topology enables the measured two-batch
    /// overlap. Result processing remains in source-batch order and each
    /// failed batch retains its existing all-or-nothing retry unit.
    private let maximumConcurrentCommitBatches: Int

    var maximumConcurrentClaimsPerBucket: Int {
        guard let control = store as? any V2FanoutDeliveryBucketConcurrencyControlling else {
            return .max
        }
        return max(1, control.maximumConcurrentClaimsPerBucket)
    }

    public init(
        store: any V2FanoutDeliveryStore,
        bucket: String? = nil,
        leaseDuration: TimeInterval = 30,
        liveNotifier: (any V2LiveSyncNotifier)? = nil,
        router: (any V2UserShardRouter)? = nil,
        retryPolicy: V2DurableRetryPolicy = .standard,
        claimScheduler: V2FanoutDeliveryClaimScheduler = .init(),
        commitBatchSize: Int = 128,
        maximumConcurrentCommitBatches: Int = 1,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(
            leaseDuration > 0 && commitBatchSize > 0 &&
                (1...2).contains(maximumConcurrentCommitBatches)
        )
        self.store = store
        self.bucket = bucket
        self.leaseDuration = leaseDuration
        self.liveNotifier = liveNotifier
        self.router = router
        self.retryPolicy = retryPolicy
        self.claimScheduler = claimScheduler
        self.commitBatchSize = commitBatchSize
        self.maximumConcurrentCommitBatches = maximumConcurrentCommitBatches
        self.now = now
    }

    public func runOnce(limit: Int) async throws -> V2FanoutDeliveryReport {
        precondition(limit > 0)
        let claimTime = now()
        var leases: [V2FanoutDeliveryLease] = []
        for lane in await claimScheduler.lanesForNextClaim() {
            leases = try await store.claimPending(
                bucket: bucket, lane: lane, now: claimTime, leaseDuration: leaseDuration, limit: limit
            )
            if !leases.isEmpty { break }
        }
        var committed = 0
        var stale = 0
        var staleRoute = 0
        var released = 0
        var paused = 0
        var committableLeases: [V2FanoutDeliveryLease] = []
        if let router, !leases.isEmpty {
            do {
                // Route the complete bounded claim together. This preserves
                // the exact epoch check per lease while replacing an N+1
                // control-plane read with one ordered batch lookup.
                let routes = try await router.routes(for: leases.map(\.targetUserID))
                guard routes.count == leases.count else { throw V2UserShardRouterError.resultCountMismatch }
                for (lease, route) in zip(leases, routes) {
                    guard route.writeIdentity != lease.observedRoute.writeIdentity else {
                        committableLeases.append(lease)
                        continue
                    }
                    // Do not write an inbox effect through a route created
                    // under a stale router epoch. Persist one fenced handoff
                    // to the current logical write owner; the new bucket then
                    // claims the same delivery and its inbox uniqueness key
                    // remains unchanged.
                    do {
                        try await store.handoff(lease, to: route)
                        staleRoute += 1
                    } catch {
                        // A handoff is a per-lease durable update. Keep the
                        // other leases on the already acquired route snapshot
                        // and retry only this fenced row on a later claim.
                        let outcome = try await scheduleRetry(for: [lease])
                        released += outcome.released
                        paused += outcome.paused
                    }
                }
            } catch {
                // A failed route lookup yields no trustworthy snapshot, so
                // retry the complete bounded claim instead of using a mixed
                // generation of routing facts.
                let outcome = try await scheduleRetry(for: leases)
                released += outcome.released
                paused += outcome.paused
            }
        } else {
            committableLeases = leases
        }
        let batches = committableLeases.chunked(into: commitBatchSize)
        for windowStart in stride(from: 0, to: batches.count, by: maximumConcurrentCommitBatches) {
            let windowEnd = Swift.min(windowStart + maximumConcurrentCommitBatches, batches.count)
            let attempts = await withTaskGroup(of: V2FanoutBatchCommitAttempt.self, returning: [V2FanoutBatchCommitAttempt].self) { group in
                for index in windowStart..<windowEnd {
                    let batch = batches[index]
                    group.addTask {
                        do {
                            let commits = try await self.store.commitBatch(batch, now: self.now())
                            guard commits.count == batch.count else {
                                return .init(index: index, commits: nil)
                            }
                            return .init(index: index, commits: commits)
                        } catch {
                            return .init(index: index, commits: nil)
                        }
                    }
                }
                var collected: [V2FanoutBatchCommitAttempt] = []
                for await attempt in group { collected.append(attempt) }
                return collected
            }
            for attempt in attempts.sorted(by: { $0.index < $1.index }) {
                let batch = batches[attempt.index]
                guard let commits = attempt.commits else {
                    // A native batch transaction has rolled every member back.
                    // Retrying the complete batch preserves that atomic boundary;
                    // the inbox unique key remains the final idempotency fence for
                    // a cross-store fallback that had already projected a target.
                    let outcome = try await scheduleRetry(for: batch)
                    released += outcome.released
                    paused += outcome.paused
                    continue
                }
                for (lease, commit) in zip(batch, commits) {
                    switch commit {
                    case .staleLease: stale += 1
                    case .committed(let sequence, _, _):
                        committed += 1
                        await liveNotifier?.notifySyncAvailable(userID: lease.targetUserID, eventID: sequence, highWatermark: sequence)
                    }
                }
            }
        }
        return .init(claimedCount: leases.count, committedCount: committed, staleCount: stale, staleRouteCount: staleRoute, releasedCount: released, pausedCount: paused)
    }

    private func scheduleRetry(for leases: [V2FanoutDeliveryLease]) async throws -> (released: Int, paused: Int) {
        var released = 0
        var paused = 0
        let failureTime = now()
        for lease in leases {
            let disposition = retryPolicy.disposition(attempt: lease.attempt, claimToken: lease.claimToken, now: failureTime)
            try await store.scheduleRetry(lease, disposition: disposition, now: failureTime)
            switch disposition {
            case .retry: released += 1
            case .pause: paused += 1
            }
        }
        return (released, paused)
    }
}

private struct V2FanoutBatchCommitAttempt: Sendable {
    let index: Int
    let commits: [V2FanoutDeliveryCommit]?
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        precondition(size > 0)
        return stride(from: 0, to: count, by: size).map { index in
            Array(self[index..<Swift.min(index + size, count)])
        }
    }
}
