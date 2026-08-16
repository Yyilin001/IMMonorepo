import Foundation
import IMV2Core

/// Minimal payload published by the outbox. The planner reloads all durable
/// fan-out details from PostgreSQL; a transport hint is never authoritative.
public struct V2FanoutPlanTrigger: Equatable, Sendable {
    public let sourceEventID: EventID
    public let planID: FanoutPlanID

    public init(sourceEventID: EventID, planID: FanoutPlanID) {
        self.sourceEventID = sourceEventID
        self.planID = planID
    }
}

public struct V2OutboxLease: Equatable, Sendable {
    public let trigger: V2FanoutPlanTrigger
    public let claimToken: UUID
    public let attempt: Int

    public init(trigger: V2FanoutPlanTrigger, claimToken: UUID, attempt: Int = 1) {
        precondition(attempt > 0)
        self.trigger = trigger
        self.claimToken = claimToken
        self.attempt = attempt
    }
}

public protocol V2RoomOutboxStore: Sendable {
    func claimPending(now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2OutboxLease]
    func markPublished(_ lease: V2OutboxLease) async throws
    func release(_ lease: V2OutboxLease) async throws
    func scheduleRetry(_ lease: V2OutboxLease, disposition: V2DurableRetryDisposition, now: Date) async throws
}

/// Optional persistence specialization used when every lease can be fenced
/// and finalized by one set-based statement. The scalar protocol remains the
/// compatibility and recovery boundary for non-PostgreSQL stores.
public protocol V2BatchRoomOutboxStore: V2RoomOutboxStore {
    func markPublished(_ leases: [V2OutboxLease]) async throws
}

/// NATS is one possible implementation. Keeping it as a protocol makes the
/// at-least-once contract testable and permits a local deterministic adapter.
public protocol V2FanoutPlanPublisher: Sendable {
    func publish(_ trigger: V2FanoutPlanTrigger) async throws
}

/// Optional publication specialization for co-located durable planners. A
/// batch either commits all of its plan pages or throws, so the relay can
/// retry every fenced lease without inventing partial acknowledgement state.
public protocol V2BatchFanoutPlanPublisher: V2FanoutPlanPublisher {
    func publishBatch(_ triggers: [V2FanoutPlanTrigger]) async throws
}

public struct V2OutboxRelayReport: Equatable, Sendable {
    public let claimedCount: Int
    public let publishedCount: Int
    public let releasedCount: Int
    public let pausedCount: Int

    public init(claimedCount: Int, publishedCount: Int, releasedCount: Int, pausedCount: Int = 0) {
        self.claimedCount = claimedCount
        self.publishedCount = publishedCount
        self.releasedCount = releasedCount
        self.pausedCount = pausedCount
    }
}

/// A bounded, caller-scheduled worker. It creates no detached task and does
/// not hold a database transaction while waiting for the broker.
public struct V2OutboxRelay: Sendable {
    private let store: any V2RoomOutboxStore
    private let publisher: any V2FanoutPlanPublisher
    private let leaseDuration: TimeInterval
    private let now: @Sendable () -> Date
    private let retryPolicy: V2DurableRetryPolicy

    public init(
        store: any V2RoomOutboxStore,
        publisher: any V2FanoutPlanPublisher,
        leaseDuration: TimeInterval = 30,
        retryPolicy: V2DurableRetryPolicy = .standard,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(leaseDuration > 0)
        self.store = store
        self.publisher = publisher
        self.leaseDuration = leaseDuration
        self.retryPolicy = retryPolicy
        self.now = now
    }

    public func runOnce(limit: Int) async throws -> V2OutboxRelayReport {
        precondition(limit > 0)
        let leases = try await store.claimPending(now: now(), leaseDuration: leaseDuration, limit: limit)
        if leases.count > 1, let batchPublisher = publisher as? any V2BatchFanoutPlanPublisher {
            return try await publishBatch(leases, with: batchPublisher)
        }
        var published = 0
        var released = 0
        var paused = 0
        for lease in leases {
            do {
                try await publisher.publish(lease.trigger)
                try await store.markPublished(lease)
                published += 1
            } catch {
                // A successful broker publish followed by a process crash is
                // intentionally retried. Consumers must deduplicate by event.
                let failureTime = now()
                let disposition = retryPolicy.disposition(attempt: lease.attempt, claimToken: lease.claimToken, now: failureTime)
                try await store.scheduleRetry(lease, disposition: disposition, now: failureTime)
                switch disposition {
                case .retry: released += 1
                case .pause: paused += 1
                }
            }
        }
        return .init(claimedCount: leases.count, publishedCount: published, releasedCount: released, pausedCount: paused)
    }

    private func publishBatch(
        _ leases: [V2OutboxLease],
        with publisher: any V2BatchFanoutPlanPublisher
    ) async throws -> V2OutboxRelayReport {
        do {
            try await publisher.publishBatch(leases.map(\.trigger))
            if let batchStore = store as? any V2BatchRoomOutboxStore {
                try await batchStore.markPublished(leases)
            } else {
                for lease in leases { try await store.markPublished(lease) }
            }
            return .init(
                claimedCount: leases.count,
                publishedCount: leases.count,
                releasedCount: 0
            )
        } catch {
            var released = 0
            var paused = 0
            for lease in leases {
                let failureTime = now()
                let disposition = retryPolicy.disposition(
                    attempt: lease.attempt,
                    claimToken: lease.claimToken,
                    now: failureTime
                )
                try await store.scheduleRetry(lease, disposition: disposition, now: failureTime)
                switch disposition {
                case .retry: released += 1
                case .pause: paused += 1
                }
            }
            return .init(
                claimedCount: leases.count,
                publishedCount: 0,
                releasedCount: released,
                pausedCount: paused
            )
        }
    }
}
