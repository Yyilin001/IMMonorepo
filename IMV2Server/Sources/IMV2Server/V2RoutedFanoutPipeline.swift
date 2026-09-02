import Foundation

public protocol V2FanoutPipelineProgressing: Sendable {
    func runRelayAndPlanOnce(
        limit: Int,
        concurrency: Int
    ) async throws -> V2OutboxRelayReport

    func runDeliveryOnce(
        claimLimit: Int,
        concurrency: Int
    ) async throws -> V2FanoutDeliveryReport
}

extension V2FanoutPipeline: V2FanoutPipelineProgressing {}

/// Runs one standard-fanout pipeline per physical room owner. Durable claims
/// remain the cross-Gateway fence; this layer only supplies bounded parallel
/// progress across independent PostgreSQL transaction/WAL domains.
public struct V2RoutedFanoutPipeline: Sendable {
    private let pipelines: [any V2FanoutPipelineProgressing]

    public init(pipelines: [V2FanoutPipeline]) throws {
        try self.init(progressors: pipelines)
    }

    public init(
        progressors: [any V2FanoutPipelineProgressing]
    ) throws {
        guard !progressors.isEmpty else {
            throw V2RoutedFanoutPipelineError.noOwners
        }
        self.pipelines = progressors
    }

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

public protocol V2FanoutCompletionReleaseProgressing: Sendable {
    func runOnce(limit: Int) async throws
        -> V2FanoutCompletionReleaseReport
}

extension V2FanoutCompletionReleaseWorker:
    V2FanoutCompletionReleaseProgressing {}

public struct V2RoutedFanoutCompletionReleaseWorker: Sendable {
    private let workers: [any V2FanoutCompletionReleaseProgressing]

    public init(workers: [V2FanoutCompletionReleaseWorker]) throws {
        try self.init(progressors: workers)
    }

    public init(
        progressors: [any V2FanoutCompletionReleaseProgressing]
    ) throws {
        guard !progressors.isEmpty else {
            throw V2RoutedFanoutPipelineError.noOwners
        }
        self.workers = progressors
    }

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

public enum V2RoutedFanoutPipelineError: Error, Equatable, Sendable {
    case noOwners
    case allOwnersFailed(Int)
}
