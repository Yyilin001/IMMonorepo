import Foundation

/// 可推进一轮扇出中继与规划的抽象。
public protocol V2FanoutPipelineProgressing: Sendable {
    /// 推进一轮发件箱中继与扇出规划。
    ///
    /// - Parameters:
    ///   - limit: 本轮最多处理的条数。
    ///   - concurrency: 并发上限。
    /// - Returns: 本轮中继统计。
    /// - Throws: 依赖失败时抛出。
    func runRelayAndPlanOnce(
        limit: Int,
        concurrency: Int
    ) async throws -> V2OutboxRelayReport

    /// 推进一轮扇出投递。
    ///
    /// - Parameters:
    ///   - claimLimit: 本轮最多认领的条数。
    ///   - concurrency: 并发上限。
    /// - Returns: 本轮投递统计。
    /// - Throws: 依赖失败时抛出。
    func runDeliveryOnce(
        claimLimit: Int,
        concurrency: Int
    ) async throws -> V2FanoutDeliveryReport
}

extension V2FanoutPipeline: V2FanoutPipelineProgressing {}

/// 为每个物理房间归属各运行一条标准扇出流水线。
///
/// 跨网关的栅栏仍由持久化认领保证；本层只在相互独立的 PostgreSQL 事务与 WAL 域之间
/// 提供有界的并行推进。
public struct V2RoutedFanoutPipeline: Sendable {
    private let pipelines: [any V2FanoutPipelineProgressing]

    /// 以具体流水线列表构造汇总实现。
    ///
    /// - Parameter pipelines: 各物理归属的流水线。
    /// - Throws: 列表为空时抛出 ``V2RoutedFanoutPipelineError/noOwners``。
    public init(pipelines: [V2FanoutPipeline]) throws {
        try self.init(progressors: pipelines)
    }

    /// 以推进实现列表构造汇总实现，供测试注入替身。
    ///
    /// - Parameter progressors: 各物理归属的推进实现。
    /// - Throws: 列表为空时抛出 ``V2RoutedFanoutPipelineError/noOwners``。
    public init(
        progressors: [any V2FanoutPipelineProgressing]
    ) throws {
        guard !progressors.isEmpty else {
            throw V2RoutedFanoutPipelineError.noOwners
        }
        self.pipelines = progressors
    }

    /// 并发推进所有归属的中继与规划并汇总计数。
    ///
    /// - Parameters:
    ///   - limit: 每个归属本轮最多处理的条数，需大于零。
    ///   - concurrencyPerOwner: 每个归属的并发上限，需大于零。
    /// - Returns: 各归属计数之和。
    /// - Throws: 全部归属都失败时抛出
    ///   ``V2RoutedFanoutPipelineError/allOwnersFailed(_:)``。
    public func runRelayAndPlanOnce(
        limit: Int,
        concurrencyPerOwner: Int
    ) async throws -> V2OutboxRelayReport {
        precondition(limit > 0 && concurrencyPerOwner > 0)
        let result = await withTaskGroup(
            of: Result<V2OutboxRelayReport, any Error>.self,
            returning: Result<V2OutboxRelayReport, V2RoutedFanoutPipelineError>.self
        ) { group in
            for pipeline in pipelines {
                group.addTask {
                    do {
                        return .success(try await pipeline.runRelayAndPlanOnce(
                            limit: limit,
                            concurrency: concurrencyPerOwner
                        ))
                    } catch { return .failure(error) }
                }
            }
            var successfulOwners = 0
            var failedOwners = 0
            var aggregate = V2OutboxRelayReport(
                claimedCount: 0,
                publishedCount: 0,
                releasedCount: 0,
                pausedCount: 0
            )
            for await result in group {
                switch result {
                case .success(let report):
                    successfulOwners += 1
                    aggregate = .init(
                        claimedCount: aggregate.claimedCount
                            + report.claimedCount,
                        publishedCount: aggregate.publishedCount
                            + report.publishedCount,
                        releasedCount: aggregate.releasedCount
                            + report.releasedCount,
                        pausedCount: aggregate.pausedCount
                            + report.pausedCount
                    )
                case .failure:
                    failedOwners += 1
                }
            }
            guard successfulOwners > 0 else {
                return .failure(.allOwnersFailed(failedOwners))
            }
            return .success(aggregate)
        }
        return try result.get()
    }

    /// 并发推进所有归属的扇出投递并汇总计数。
    ///
    /// - Parameters:
    ///   - claimLimit: 每个归属本轮最多认领的条数，需大于零。
    ///   - concurrencyPerOwner: 每个归属的并发上限，需大于零。
    /// - Returns: 各归属计数之和。
    /// - Throws: 全部归属都失败时抛出
    ///   ``V2RoutedFanoutPipelineError/allOwnersFailed(_:)``。
    public func runDeliveryOnce(
        claimLimit: Int,
        concurrencyPerOwner: Int
    ) async throws -> V2FanoutDeliveryReport {
        precondition(claimLimit > 0 && concurrencyPerOwner > 0)
        let result = await withTaskGroup(
            of: Result<V2FanoutDeliveryReport, any Error>.self,
            returning: Result<V2FanoutDeliveryReport, V2RoutedFanoutPipelineError>.self
        ) { group in
            for pipeline in pipelines {
                group.addTask {
                    do {
                        return .success(try await pipeline.runDeliveryOnce(
                            claimLimit: claimLimit,
                            concurrency: concurrencyPerOwner
                        ))
                    } catch { return .failure(error) }
                }
            }
            var successfulOwners = 0
            var failedOwners = 0
            var aggregate = V2FanoutDeliveryReport(
                claimedCount: 0,
                committedCount: 0,
                staleCount: 0,
                staleRouteCount: 0,
                releasedCount: 0,
                pausedCount: 0
            )
            for await result in group {
                switch result {
                case .success(let report):
                    successfulOwners += 1
                    aggregate = .init(
                        claimedCount: aggregate.claimedCount
                            + report.claimedCount,
                        committedCount: aggregate.committedCount
                            + report.committedCount,
                        staleCount: aggregate.staleCount + report.staleCount,
                        staleRouteCount: aggregate.staleRouteCount
                            + report.staleRouteCount,
                        releasedCount: aggregate.releasedCount
                            + report.releasedCount,
                        pausedCount: aggregate.pausedCount
                            + report.pausedCount
                    )
                case .failure:
                    failedOwners += 1
                }
            }
            guard successfulOwners > 0 else {
                return .failure(.allOwnersFailed(failedOwners))
            }
            return .success(aggregate)
        }
        return try result.get()
    }
}

/// 可推进一轮完成单元释放的能力。
public protocol V2FanoutCompletionReleaseProgressing: Sendable {
    /// 执行一轮有界容量释放。
    ///
    /// - Parameter limit: 本轮最多处理的工作单元数。
    /// - Returns: 本轮释放统计。
    /// - Throws: 依赖失败时抛出。
    func runOnce(limit: Int) async throws
        -> V2FanoutCompletionReleaseReport
}

extension V2FanoutCompletionReleaseWorker:
    V2FanoutCompletionReleaseProgressing {}

/// 汇总各物理归属的扇出完成单元释放工作器。
public struct V2RoutedFanoutCompletionReleaseWorker: Sendable {
    private let workers: [any V2FanoutCompletionReleaseProgressing]

    /// 以具体工作器列表构造汇总实现。
    ///
    /// - Parameter workers: 各物理归属的释放工作器。
    /// - Throws: 列表为空时抛出 ``V2RoutedFanoutPipelineError/noOwners``。
    public init(workers: [V2FanoutCompletionReleaseWorker]) throws {
        try self.init(progressors: workers)
    }

    /// 以推进实现列表构造汇总实现，供测试注入替身。
    ///
    /// - Parameter progressors: 各物理归属的推进实现。
    /// - Throws: 列表为空时抛出 ``V2RoutedFanoutPipelineError/noOwners``。
    public init(
        progressors: [any V2FanoutCompletionReleaseProgressing]
    ) throws {
        guard !progressors.isEmpty else {
            throw V2RoutedFanoutPipelineError.noOwners
        }
        self.workers = progressors
    }

    /// 并发执行所有归属的容量释放并汇总计数。
    ///
    /// - Parameter limitPerOwner: 每个归属单轮最多处理的工作单元数，需大于零。
    /// - Returns: 释放数量与关闭计划数量之和。
    /// - Throws: 全部归属都失败时抛出
    ///   ``V2RoutedFanoutPipelineError/allOwnersFailed(_:)``。
    public func runOnce(
        limitPerOwner: Int
    ) async throws -> V2FanoutCompletionReleaseReport {
        precondition(limitPerOwner > 0)
        let result = await withTaskGroup(
            of: Result<V2FanoutCompletionReleaseReport, any Error>.self,
            returning: Result<
                V2FanoutCompletionReleaseReport,
                V2RoutedFanoutPipelineError
            >.self
        ) { group in
            for worker in workers {
                group.addTask {
                    do {
                        return .success(
                            try await worker.runOnce(limit: limitPerOwner)
                        )
                    } catch { return .failure(error) }
                }
            }
            var successfulOwners = 0
            var failedOwners = 0
            var released = 0
            var closed = 0
            for await result in group {
                switch result {
                case .success(let report):
                    successfulOwners += 1
                    released += report.releasedCount
                    closed += report.closedPlanCount
                case .failure:
                    failedOwners += 1
                }
            }
            guard successfulOwners > 0 else {
                return .failure(.allOwnersFailed(failedOwners))
            }
            return .success(.init(
                releasedCount: released,
                closedPlanCount: closed
            ))
        }
        return try result.get()
    }
}

/// 扇出流水线汇总错误。
public enum V2RoutedFanoutPipelineError: Error, Equatable, Sendable {
    /// 未配置任何物理归属。
    case noOwners
    /// 全部归属都失败，参数为失败归属数量。
    case allOwnersFailed(Int)
}
