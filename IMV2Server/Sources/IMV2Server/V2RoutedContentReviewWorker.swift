/// 从每个物理房间归属清理内容审核任务的汇总工作器。
///
/// 单个归属失败不会阻止健康归属处理自己的消息；全部归属都失败时会显式抛出，
/// 让运行时保持正常的重试节奏而不是静默丢弃本轮结果。
public struct V2RoutedContentReviewWorker: Sendable {
    private let workers: [any V2ContentReviewProgressing]

    /// 以具体审核工作器列表构造汇总工作器。
    ///
    /// - Parameter workers: 各物理归属的审核工作器。
    /// - Throws: 列表为空时抛出 ``V2RoutedContentReviewWorkerError/noOwners``。
    public init(workers: [V2ContentReviewWorker]) throws {
        try self.init(progressors: workers)
    }

    /// 以进度推进实现列表构造汇总工作器，供测试注入替身。
    ///
    /// - Parameter progressors: 各物理归属的推进实现。
    /// - Throws: 列表为空时抛出 ``V2RoutedContentReviewWorkerError/noOwners``。
    public init(progressors: [any V2ContentReviewProgressing]) throws {
        guard !progressors.isEmpty else {
            throw V2RoutedContentReviewWorkerError.noOwners
        }
        workers = progressors
    }

    /// 并发推进所有归属各一轮并汇总计数。
    ///
    /// - Parameter limitPerOwner: 每个归属单轮最多处理的任务数，需大于零，且乘以归属数不超过 Int.max。
    /// - Returns: 各归属计数之和。
    /// - Throws: 上限非正或总预算无法表示时抛出 ``V2ContentReviewWorkerError/invalidLimit``；
    ///   全部归属都失败时抛出
    ///   ``V2RoutedContentReviewWorkerError/allOwnersFailed(_:)``。
    public func runOnce(limitPerOwner: Int) async throws
        -> V2ContentReviewReport {
        // Each owner report is bounded by its claim limit. Validate the total
        // before starting work so aggregation cannot overflow after side effects.
        guard limitPerOwner > 0, limitPerOwner <= Int.max / workers.count else {
            throw V2ContentReviewWorkerError.invalidLimit
        }
        let result = await withTaskGroup(
            of: Result<V2ContentReviewReport, any Error>.self,
            returning: Result<
                V2ContentReviewReport,
                V2RoutedContentReviewWorkerError
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
            var claimed = 0
            var resolved = 0
            var redacted = 0
            var released = 0
            for await ownerResult in group {
                switch ownerResult {
                case .success(let report):
                    successfulOwners += 1
                    claimed += report.claimedCount
                    resolved += report.resolvedCount
                    redacted += report.redactedCount
                    released += report.releasedCount
                case .failure:
                    failedOwners += 1
                }
            }
            guard successfulOwners > 0 else {
                return .failure(.allOwnersFailed(failedOwners))
            }
            return .success(.init(
                claimedCount: claimed,
                resolvedCount: resolved,
                redactedCount: redacted,
                releasedCount: released
            ))
        }
        return try result.get()
    }
}

/// 可推进一轮内容审核工作的能力。
public protocol V2ContentReviewProgressing: Sendable {
    /// 推进一轮内容审核。
    ///
    /// - Parameter limit: 本轮最多处理的任务数。
    /// - Returns: 本轮统计报告；每项计数均在 0...limit 内。
    /// - Throws: 存储或下游依赖失败时抛出。
    func runOnce(limit: Int) async throws -> V2ContentReviewReport
}

extension V2ContentReviewWorker: V2ContentReviewProgressing {}

/// 汇总内容审核工作器错误。
public enum V2RoutedContentReviewWorkerError:
    Error,
    Equatable,
    Sendable {
    /// 未配置任何物理归属。
    case noOwners
    /// 全部归属都失败，参数为失败归属数量。
    case allOwnersFailed(Int)
}
