import Foundation

/// 持久化房间发件箱的进程内消费者。
///
/// 每一步都可以安全地在多个网关副本上运行：认领会栅栏掉并发工作器，
/// 规划是幂等的，投递存储对每个来源事件与目标用户恰好提交一条用户同步记录。
public struct V2LocalFanoutPlanPublisher: V2BatchFanoutPlanPublisher {
    private let planner: V2FanoutPlanner

    /// 以扇出规划器构造本地发布器。
    ///
    /// - Parameter planner: 执行规划的规划器。
    public init(planner: V2FanoutPlanner) {
        self.planner = planner
    }

    /// 发布单个扇出触发。
    ///
    /// - Parameter trigger: 待发布的触发。
    /// - Throws: 规划失败时抛出。
    public func publish(_ trigger: V2FanoutPlanTrigger) async throws {
        _ = try await planner.plan(trigger)
    }

    /// 批量发布扇出触发。
    ///
    /// - Parameter triggers: 本批触发。
    /// - Throws: 任一触发规划失败时抛出。
    public func publishBatch(_ triggers: [V2FanoutPlanTrigger]) async throws {
        _ = try await planner.planBatch(triggers)
    }
}

/// 单轮扇出流水线统计。
public struct V2FanoutPipelineReport: Equatable, Sendable {
    /// 发件箱中继统计。
    public let relay: V2OutboxRelayReport
    /// 投递统计。
    public let delivery: V2FanoutDeliveryReport

    /// 组合中继与投递统计。
    ///
    /// - Parameters:
    ///   - relay: 发件箱中继统计。
    ///   - delivery: 投递统计。
    public init(relay: V2OutboxRelayReport, delivery: V2FanoutDeliveryReport) {
        self.relay = relay
        self.delivery = delivery
    }
}

/// 房间发件箱 → 不可变扇出计划 → 用户同步投递的单次有界推进。
///
/// 规划与投递阶段各有显式的进程内并发上限；跨副本栅栏仍由持久化认领承担。
/// 调度与取消由运行时负责。
public struct V2FanoutPipeline: Sendable {
    private let relay: V2OutboxRelay
    private let deliveryWorkers: [V2FanoutDeliveryWorker]
    private let telemetry: any V2TelemetrySink
    private let monotonicNow: @Sendable () -> ContinuousClock.Instant

    /// 组合中继、单个投递工作器与遥测。
    ///
    /// - Parameters:
    ///   - relay: 发件箱中继。
    ///   - deliveryWorker: 投递工作器。
    ///   - telemetry: 遥测接收器。
    ///   - monotonicNow: 可注入的单调时钟读取函数。
    public init(relay: V2OutboxRelay, deliveryWorker: V2FanoutDeliveryWorker, telemetry: any V2TelemetrySink, monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.init(relay: relay, deliveryWorkers: [deliveryWorker], telemetry: telemetry, monotonicNow: monotonicNow)
    }

    /// 组合中继、多个投递工作器与遥测。
    ///
    /// 每个逻辑桶在每次流水线推进中都会获得一次有界认领机会；
    /// `deliveryConcurrency` 始终是进程级上限，不会随桶数量被隐式放大。
    ///
    /// - Parameters:
    ///   - relay: 发件箱中继。
    ///   - deliveryWorkers: 投递工作器列表，需非空。
    ///   - telemetry: 遥测接收器。
    ///   - monotonicNow: 可注入的单调时钟读取函数。
    public init(relay: V2OutboxRelay, deliveryWorkers: [V2FanoutDeliveryWorker], telemetry: any V2TelemetrySink, monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        precondition(!deliveryWorkers.isEmpty)
        self.relay = relay
        self.deliveryWorkers = deliveryWorkers
        self.telemetry = telemetry
        self.monotonicNow = monotonicNow
    }

    /// 以同一上限与单并发推进一轮中继与投递。
    ///
    /// - Parameter limit: 本轮中继与投递各自的上限，需大于零。
    /// - Returns: 本轮流水线统计。
    /// - Throws: 中继或投递失败时抛出。
    public func runOnce(limit: Int) async throws -> V2FanoutPipelineReport {
        try await runOnce(
            relayPlannerLimit: limit,
            deliveryClaimLimit: limit,
            plannerConcurrency: 1,
            deliveryConcurrency: 1
        )
    }

    /// 以指定并发推进一轮流水线。
    ///
    /// 先完成全部有界规划认领，再开始投递认领，使新发布的计划在同一次运行时推进中
    /// 就具备被投影的资格。`limit` 作用于每次工作器调用，而不是总上限。
    ///
    /// - Parameters:
    ///   - limit: 各阶段处理上限，需大于零。
    ///   - plannerConcurrency: 规划并发上限，需大于零。
    ///   - deliveryConcurrency: 投递并发上限，需大于零。
    /// - Returns: 本轮流水线统计。
    /// - Throws: 中继或投递失败时抛出。
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

    /// 以分别的上限推进一轮流水线。
    ///
    /// 房间发件箱与规划阶段、基于租约的投递阶段各有独立上限：
    /// 较大的投递认领量可以降低 PostgreSQL 认领开销，又不会顺带放大其他无关后台工作器。
    ///
    /// - Parameters:
    ///   - relayPlannerLimit: 中继与规划阶段上限，需大于零。
    ///   - deliveryClaimLimit: 投递认领上限，需大于零。
    ///   - plannerConcurrency: 规划并发上限，需大于零。
    ///   - deliveryConcurrency: 投递并发上限，需大于零。
    /// - Returns: 本轮流水线统计。
    /// - Throws: 中继或投递失败时抛出。
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
        let startedAt = monotonicNow()
        do {
            let relayStartedAt = monotonicNow()
            let relay = try await runRelays(limit: relayPlannerLimit, concurrency: plannerConcurrency)
            let relayElapsedMilliseconds = v2ElapsedMilliseconds(since: relayStartedAt, now: monotonicNow())
            let deliveryStartedAt = monotonicNow()
            let delivery = try await runDeliveries(limit: deliveryClaimLimit, concurrency: deliveryConcurrency)
            let deliveryElapsedMilliseconds = v2ElapsedMilliseconds(since: deliveryStartedAt, now: monotonicNow())
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
                    elapsedMilliseconds: v2ElapsedMilliseconds(since: startedAt, now: monotonicNow())
                ))
            }
            return report
        } catch {
            await telemetry.record(.fanoutFailure(traceID: traceID, stage: .pipeline, elapsedMilliseconds: v2ElapsedMilliseconds(since: startedAt, now: monotonicNow())))
            throw error
        }
    }

    /// 只推进房间发件箱发布与计划创建，不等候在途投递排空。
    ///
    /// 运行时可以较高频地调度该入口，以约束「房间事件提交到持久化计划生成」的时延。
    ///
    /// - Parameters:
    ///   - limit: 本轮处理上限，需大于零。
    ///   - concurrency: 并发上限，需大于零。
    /// - Returns: 本轮中继统计。
    /// - Throws: 中继失败时抛出。
    public func runRelayAndPlanOnce(
        limit: Int,
        concurrency: Int
    ) async throws -> V2OutboxRelayReport {
        precondition(limit > 0 && concurrency > 0)
        let traceID = UUID()
        let startedAt = monotonicNow()
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
                    relayElapsedMilliseconds: v2ElapsedMilliseconds(since: startedAt, now: monotonicNow()),
                    deliveryElapsedMilliseconds: 0,
                    elapsedMilliseconds: v2ElapsedMilliseconds(since: startedAt, now: monotonicNow())
                ))
            }
            return relay
        } catch {
            await telemetry.record(.fanoutFailure(traceID: traceID, stage: .relay, elapsedMilliseconds: v2ElapsedMilliseconds(since: startedAt, now: monotonicNow())))
            throw error
        }
    }

    /// 只在租约支撑下推进用户投递。
    ///
    /// 它刻意可以独立于规划阶段调用，
    /// 这样一次耗时的投影排空就不会把自身耗时叠加到新消息规划延迟上。
    ///
    /// - Parameters:
    ///   - claimLimit: 本次最多认领的投递条数。
    ///   - concurrency: 并发处理的工作协程数。
    /// - Returns: 本次投递报告。
    /// - Throws: 认领或投递失败时抛出。
    public func runDeliveryOnce(
        claimLimit: Int,
        concurrency: Int
    ) async throws -> V2FanoutDeliveryReport {
        precondition(claimLimit > 0 && concurrency > 0)
        let traceID = UUID()
        let startedAt = monotonicNow()
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
                    deliveryElapsedMilliseconds: v2ElapsedMilliseconds(since: startedAt, now: monotonicNow()),
                    elapsedMilliseconds: v2ElapsedMilliseconds(since: startedAt, now: monotonicNow())
                ))
            }
            return delivery
        } catch {
            await telemetry.record(.fanoutFailure(traceID: traceID, stage: .delivery, elapsedMilliseconds: v2ElapsedMilliseconds(since: startedAt, now: monotonicNow())))
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
