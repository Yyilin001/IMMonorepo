import Foundation

/// In-process consumer for a durable room outbox. Every step remains safe to
/// run on multiple gateway replicas: claims fence concurrent workers, planning
/// is idempotent, and the delivery store commits a user-sync record exactly
/// once for each source event and target user.
public struct V2LocalFanoutPlanPublisher: V2BatchFanoutPlanPublisher {
    private let planner: V2FanoutPlanner

    public init(planner: V2FanoutPlanner) {
        self.planner = planner
    }

    public func publish(_ trigger: V2FanoutPlanTrigger) async throws {
        _ = try await planner.plan(trigger)
    }

    public func publishBatch(_ triggers: [V2FanoutPlanTrigger]) async throws {
        _ = try await planner.planBatch(triggers)
    }
}

public struct V2FanoutPipelineReport: Equatable, Sendable {
    public let relay: V2OutboxRelayReport
    public let delivery: V2FanoutDeliveryReport

    public init(relay: V2OutboxRelayReport, delivery: V2FanoutDeliveryReport) {
        self.relay = relay
        self.delivery = delivery
    }
}

/// One bounded progression of room outbox -> immutable fan-out plan ->
/// user-sync delivery. The planner and delivery phases each have an explicit
/// per-process concurrency cap; durable claims remain the cross-replica
/// fence. Scheduling and cancellation are owned by the runtime.
public struct V2FanoutPipeline: Sendable {
    private let relay: V2OutboxRelay
    private let deliveryWorkers: [V2FanoutDeliveryWorker]
    private let telemetry: any V2TelemetrySink
    private let now: @Sendable () -> Date

    public init(relay: V2OutboxRelay, deliveryWorker: V2FanoutDeliveryWorker, telemetry: any V2TelemetrySink, now: @escaping @Sendable () -> Date = Date.init) {
        self.init(relay: relay, deliveryWorkers: [deliveryWorker], telemetry: telemetry, now: now)
    }

    /// Each logical bucket receives a bounded claim pass on every pipeline
    /// tick. `deliveryConcurrency` remains a process-wide cap, not a hidden
    /// multiplier by bucket count.
    public init(relay: V2OutboxRelay, deliveryWorkers: [V2FanoutDeliveryWorker], telemetry: any V2TelemetrySink, now: @escaping @Sendable () -> Date = Date.init) {
        precondition(!deliveryWorkers.isEmpty)
        self.relay = relay
        self.deliveryWorkers = deliveryWorkers
        self.telemetry = telemetry
        self.now = now
    }

    public func runOnce(limit: Int) async throws -> V2FanoutPipelineReport {
        try await runOnce(
            relayPlannerLimit: limit,
            deliveryClaimLimit: limit,
            plannerConcurrency: 1,
            deliveryConcurrency: 1
        )
    }

    /// Runs all bounded planner claims before starting delivery claims, so a
    /// newly published plan is eligible for projection in the same runtime
    /// tick. `limit` applies to each worker invocation, not the aggregate.
    public func runOnce(
        limit: Int,
        plannerConcurrency: Int,
        deliveryConcurrency: Int
    ) async throws -> V2FanoutPipelineReport {
        try await runOnce(
            relayPlannerLimit: limit,
            deliveryClaimLimit: limit,
            plannerConcurrency: plannerConcurrency,
            deliveryConcurrency: deliveryConcurrency
        )
    }

    /// Runs one bounded pipeline progression with independent limits for the
    /// room-outbox/planning phase and the lease-backed delivery phase. A large
    /// delivery claim can reduce PostgreSQL claim overhead without widening
    /// unrelated background workers.
    public func runOnce(
        relayPlannerLimit: Int,
        deliveryClaimLimit: Int,
        plannerConcurrency: Int,
        deliveryConcurrency: Int
    ) async throws -> V2FanoutPipelineReport {
        precondition(
            relayPlannerLimit > 0 && deliveryClaimLimit > 0 &&
            plannerConcurrency > 0 && deliveryConcurrency > 0
        )
        let traceID = UUID()
        let startedAt = now()
        do {
            let relayStartedAt = now()
            let relay = try await runRelays(limit: relayPlannerLimit, concurrency: plannerConcurrency)
            let relayElapsedMilliseconds = v2ElapsedMilliseconds(since: relayStartedAt, now: now())
            let deliveryStartedAt = now()
            let delivery = try await runDeliveries(limit: deliveryClaimLimit, concurrency: deliveryConcurrency)
            let deliveryElapsedMilliseconds = v2ElapsedMilliseconds(since: deliveryStartedAt, now: now())
            let report = V2FanoutPipelineReport(relay: relay, delivery: delivery)
            // The runtime polls frequently while idle. Emitting an all-zero
            // structured event on each poll turns normal quiescence into log
            // and metric noise; operational liveness comes from the private
            // scrape, while fan-out telemetry is reserved for actual work or
            // recovery/release activity.
            if report.containsDurableWork {
                await telemetry.record(.fanoutProgress(
                    traceID: traceID,
                    claimedOutboxRows: relay.claimedCount,
                    publishedOutboxRows: relay.publishedCount,
                    releasedOutboxRows: relay.releasedCount,
                    pausedOutboxRows: relay.pausedCount,
                    claimedDeliveries: delivery.claimedCount,
                    committedDeliveries: delivery.committedCount,
                    staleDeliveries: delivery.staleCount,
                    staleRouteDeliveries: delivery.staleRouteCount,
                    releasedDeliveries: delivery.releasedCount,
                    pausedDeliveries: delivery.pausedCount,
                    relayElapsedMilliseconds: relayElapsedMilliseconds,
                    deliveryElapsedMilliseconds: deliveryElapsedMilliseconds,
                    elapsedMilliseconds: v2ElapsedMilliseconds(since: startedAt, now: now())
                ))
            }
            return report
        } catch {
            await telemetry.record(.fanoutFailure(traceID: traceID, stage: .pipeline, elapsedMilliseconds: v2ElapsedMilliseconds(since: startedAt, now: now())))
            throw error
        }
    }

    /// Progresses room-outbox publication and plan creation without waiting
    /// for an in-flight delivery drain. Runtimes can schedule this frequently
    /// to bound the time from a committed room event to a durable plan.
    public func runRelayAndPlanOnce(
        limit: Int,
        concurrency: Int
    ) async throws -> V2OutboxRelayReport {
        precondition(limit > 0 && concurrency > 0)
        let traceID = UUID()
        let startedAt = now()
        do {
            let relay = try await runRelays(limit: limit, concurrency: concurrency)
            if relay.containsDurableWork {
                await telemetry.record(.fanoutProgress(
                    traceID: traceID,
                    claimedOutboxRows: relay.claimedCount,
                    publishedOutboxRows: relay.publishedCount,
                    releasedOutboxRows: relay.releasedCount,
                    pausedOutboxRows: relay.pausedCount,
                    claimedDeliveries: 0,
                    committedDeliveries: 0,
                    staleDeliveries: 0,
                    staleRouteDeliveries: 0,
                    releasedDeliveries: 0,
                    pausedDeliveries: 0,
                    relayElapsedMilliseconds: v2ElapsedMilliseconds(since: startedAt, now: now()),
                    deliveryElapsedMilliseconds: 0,
                    elapsedMilliseconds: v2ElapsedMilliseconds(since: startedAt, now: now())
                ))
            }
            return relay
        } catch {
            await telemetry.record(.fanoutFailure(traceID: traceID, stage: .relay, elapsedMilliseconds: v2ElapsedMilliseconds(since: startedAt, now: now())))
            throw error
        }
    }

    /// Progresses only lease-backed user delivery. It is intentionally
    /// callable independently from planning so a long projection drain does
    /// not add its duration to new-message planning latency.
    public func runDeliveryOnce(
        claimLimit: Int,
        concurrency: Int
    ) async throws -> V2FanoutDeliveryReport {
        precondition(claimLimit > 0 && concurrency > 0)
        let traceID = UUID()
        let startedAt = now()
        do {
            let delivery = try await runDeliveries(limit: claimLimit, concurrency: concurrency)
            if delivery.containsDurableWork {
                await telemetry.record(.fanoutProgress(
                    traceID: traceID,
                    claimedOutboxRows: 0,
                    publishedOutboxRows: 0,
                    releasedOutboxRows: 0,
                    pausedOutboxRows: 0,
                    claimedDeliveries: delivery.claimedCount,
                    committedDeliveries: delivery.committedCount,
                    staleDeliveries: delivery.staleCount,
                    staleRouteDeliveries: delivery.staleRouteCount,
                    releasedDeliveries: delivery.releasedCount,
                    pausedDeliveries: delivery.pausedCount,
                    relayElapsedMilliseconds: 0,
                    deliveryElapsedMilliseconds: v2ElapsedMilliseconds(since: startedAt, now: now()),
                    elapsedMilliseconds: v2ElapsedMilliseconds(since: startedAt, now: now())
                ))
            }
            return delivery
        } catch {
            await telemetry.record(.fanoutFailure(traceID: traceID, stage: .delivery, elapsedMilliseconds: v2ElapsedMilliseconds(since: startedAt, now: now())))
            throw error
        }
    }

    private func runRelays(limit: Int, concurrency: Int) async throws -> V2OutboxRelayReport {
        try await withThrowingTaskGroup(of: V2OutboxRelayReport.self, returning: V2OutboxRelayReport.self) { group in
            for _ in 0..<concurrency {
                group.addTask { try await relay.runOnce(limit: limit) }
            }
            var aggregate = V2OutboxRelayReport(claimedCount: 0, publishedCount: 0, releasedCount: 0, pausedCount: 0)
            for try await report in group {
                aggregate = .init(
                    claimedCount: aggregate.claimedCount + report.claimedCount,
                    publishedCount: aggregate.publishedCount + report.publishedCount,
                    releasedCount: aggregate.releasedCount + report.releasedCount,
                    pausedCount: aggregate.pausedCount + report.pausedCount
                )
            }
            return aggregate
        }
    }

    private func runDeliveries(limit: Int, concurrency: Int) async throws -> V2FanoutDeliveryReport {
        if deliveryWorkers.count > 1 {
            return try await runBucketedDeliveries(limit: limit, concurrency: concurrency)
        }
        let deliveryWorker = deliveryWorkers[0]
        let effectiveConcurrency = min(concurrency, deliveryWorker.maximumConcurrentClaimsPerBucket)
        return try await withThrowingTaskGroup(of: V2FanoutDeliveryReport.self, returning: V2FanoutDeliveryReport.self) { group in
            for partitionIndex in 0..<effectiveConcurrency {
                let partition = V2FanoutDeliveryClaimPartition(
                    index: partitionIndex,
                    count: effectiveConcurrency
                )
                group.addTask {
                    try await deliveryWorker.runOnce(
                        limit: limit,
                        claimPartition: partition
                    )
                }
            }
            var aggregate = V2FanoutDeliveryReport(claimedCount: 0, committedCount: 0, staleCount: 0, staleRouteCount: 0, releasedCount: 0, pausedCount: 0)
            for try await report in group {
                aggregate = .init(
                    claimedCount: aggregate.claimedCount + report.claimedCount,
                    committedCount: aggregate.committedCount + report.committedCount,
                    staleCount: aggregate.staleCount + report.staleCount,
                    staleRouteCount: aggregate.staleRouteCount + report.staleRouteCount,
                    releasedCount: aggregate.releasedCount + report.releasedCount,
                    pausedCount: aggregate.pausedCount + report.pausedCount
                )
            }
            return aggregate
        }
    }

    private func runBucketedDeliveries(limit: Int, concurrency: Int) async throws -> V2FanoutDeliveryReport {
        return try await withThrowingTaskGroup(of: V2FanoutDeliveryReport.self, returning: V2FanoutDeliveryReport.self) { group in
            var nextWorker = 0
            let initialWorkers = min(concurrency, deliveryWorkers.count)
            for _ in 0..<initialWorkers {
                let worker = deliveryWorkers[nextWorker]
                nextWorker += 1
                group.addTask { try await worker.runOnce(limit: limit) }
            }
            var aggregate = V2FanoutDeliveryReport(claimedCount: 0, committedCount: 0, staleCount: 0, staleRouteCount: 0, releasedCount: 0, pausedCount: 0)
            while let report = try await group.next() {
                aggregate = aggregateDeliveries(aggregate, report)
                if nextWorker < deliveryWorkers.count {
                    let worker = deliveryWorkers[nextWorker]
                    nextWorker += 1
                    group.addTask { try await worker.runOnce(limit: limit) }
                }
            }
            return aggregate
        }
    }

    private func aggregateDeliveries(_ lhs: V2FanoutDeliveryReport, _ rhs: V2FanoutDeliveryReport) -> V2FanoutDeliveryReport {
        .init(
            claimedCount: lhs.claimedCount + rhs.claimedCount,
            committedCount: lhs.committedCount + rhs.committedCount,
            staleCount: lhs.staleCount + rhs.staleCount,
            staleRouteCount: lhs.staleRouteCount + rhs.staleRouteCount,
            releasedCount: lhs.releasedCount + rhs.releasedCount,
            pausedCount: lhs.pausedCount + rhs.pausedCount
        )
    }
}

private extension V2FanoutPipelineReport {
    var containsDurableWork: Bool {
        relay.claimedCount > 0 || relay.publishedCount > 0 || relay.releasedCount > 0 || relay.pausedCount > 0 ||
        delivery.claimedCount > 0 || delivery.committedCount > 0 || delivery.staleCount > 0 ||
        delivery.staleRouteCount > 0 || delivery.releasedCount > 0 || delivery.pausedCount > 0
    }
}

private extension V2OutboxRelayReport {
    var containsDurableWork: Bool {
        claimedCount > 0 || publishedCount > 0 || releasedCount > 0 || pausedCount > 0
    }
}

private extension V2FanoutDeliveryReport {
    var containsDurableWork: Bool {
        claimedCount > 0 || committedCount > 0 || staleCount > 0 || staleRouteCount > 0 ||
        releasedCount > 0 || pausedCount > 0
    }
}
