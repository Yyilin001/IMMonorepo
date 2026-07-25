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

    public init(sourceEventID: EventID, targetUserID: UserID, projectionKind: String, completionUnitID: CompletionUnitID, observedRoute: V2UserShardRoute, claimToken: UUID, attempt: Int = 1) {
        precondition(attempt > 0)
        self.sourceEventID = sourceEventID
        self.targetUserID = targetUserID
        self.projectionKind = projectionKind
        self.completionUnitID = completionUnitID
        self.observedRoute = observedRoute
        self.claimToken = claimToken
        self.attempt = attempt
    }
}

public enum V2FanoutDeliveryCommit: Equatable, Sendable {
    case staleLease
    case committed(userSyncSequence: UInt64, releasedCompletionUnit: Bool, closedPlan: Bool)
}

public protocol V2FanoutDeliveryStore: Sendable {
    func claimPending(bucket: String?, now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2FanoutDeliveryLease]
    func commit(_ lease: V2FanoutDeliveryLease, now: Date) async throws -> V2FanoutDeliveryCommit
    /// Moves a claimed, not-yet-projected delivery to the router's current
    /// logical write bucket. Implementations must fence this update with the
    /// lease token; it is a handoff of one durable inbox effect, never a
    /// second delivery or a terminal skip.
    func handoff(_ lease: V2FanoutDeliveryLease, to route: V2UserShardRoute) async throws
    func release(_ lease: V2FanoutDeliveryLease) async throws
    func scheduleRetry(_ lease: V2FanoutDeliveryLease, disposition: V2DurableRetryDisposition, now: Date) async throws
}

public extension V2FanoutDeliveryStore {
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

    public init(
        store: any V2FanoutDeliveryStore,
        bucket: String? = nil,
        leaseDuration: TimeInterval = 30,
        liveNotifier: (any V2LiveSyncNotifier)? = nil,
        router: (any V2UserShardRouter)? = nil,
        retryPolicy: V2DurableRetryPolicy = .standard,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(leaseDuration > 0)
        self.store = store
        self.bucket = bucket
        self.leaseDuration = leaseDuration
        self.liveNotifier = liveNotifier
        self.router = router
        self.retryPolicy = retryPolicy
        self.now = now
    }

    public func runOnce(limit: Int) async throws -> V2FanoutDeliveryReport {
        precondition(limit > 0)
        let leases = try await store.claimPending(bucket: bucket, now: now(), leaseDuration: leaseDuration, limit: limit)
        var committed = 0
        var stale = 0
        var staleRoute = 0
        var released = 0
        var paused = 0
        for lease in leases {
            do {
                if let router {
                    let routes = try await router.routes(for: [lease.targetUserID])
                    guard routes.count == 1 else { throw V2UserShardRouterError.resultCountMismatch }
                    guard routes[0].writeIdentity == lease.observedRoute.writeIdentity else {
                        // Do not write an inbox effect through a route created
                        // under a stale router epoch. Persist one fenced
                        // handoff to the current logical write owner; the new
                        // bucket then claims the same delivery and its inbox
                        // uniqueness key remains unchanged.
                        try await store.handoff(lease, to: routes[0])
                        staleRoute += 1
                        continue
                    }
                }
                switch try await store.commit(lease, now: now()) {
                case .staleLease: stale += 1
                case .committed(let sequence, _, _):
                    committed += 1
                    await liveNotifier?.notifySyncAvailable(userID: lease.targetUserID, eventID: sequence, highWatermark: sequence)
                }
            } catch {
                let failureTime = now()
                let disposition = retryPolicy.disposition(attempt: lease.attempt, claimToken: lease.claimToken, now: failureTime)
                try await store.scheduleRetry(lease, disposition: disposition, now: failureTime)
                switch disposition {
                case .retry: released += 1
                case .pause: paused += 1
                }
            }
        }
        return .init(claimedCount: leases.count, committedCount: committed, staleCount: stale, staleRouteCount: staleRoute, releasedCount: released, pausedCount: paused)
    }
}
