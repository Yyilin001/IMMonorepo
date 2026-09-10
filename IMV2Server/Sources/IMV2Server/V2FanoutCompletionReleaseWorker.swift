import Foundation

/// 扇出完成第二阶段所需的持久化能力。
///
/// 实现以跳过已加锁行的语义领取有界批次，并在单个事务内原子提交全部容量释放。
/// 事件、房间与分片标识都留在持久化边界内部，避免指标意外获得高基数标签。
public protocol V2FanoutCompletionReleaseStore: Sendable {
    /// 释放处于终态、可回收容量的目标工作单元。
    ///
    /// - Parameters:
    ///   - now: 本次判定的服务端时刻。
    ///   - limit: 本次最多处理的工作单元数。
    /// - Returns: 本次释放数量与其中关闭的计划数量。
    /// - Throws: 持久化失败时抛出。
    func releaseTerminalCompletionUnits(
        now: Date,
        limit: Int
    ) async throws -> V2FanoutCompletionReleaseReport
}

/// 单轮容量释放的统计结果。
public struct V2FanoutCompletionReleaseReport: Equatable, Sendable {
    /// 本次释放的工作单元数量。
    public let releasedCount: Int
    /// 因本次释放而关闭的扇出计划数量。
    public let closedPlanCount: Int

    /// 保存统计结果。
    ///
    /// - Parameters:
    ///   - releasedCount: 释放的工作单元数量，需非负。
    ///   - closedPlanCount: 关闭的计划数量，需非负且不超过 `releasedCount`。
    ///
    /// 取值不满足上述关系时直接失败，避免统计口径错误的报告进入运行路径。
    public init(releasedCount: Int, closedPlanCount: Int) {
        precondition(releasedCount >= 0 && closedPlanCount >= 0 && closedPlanCount <= releasedCount)
        self.releasedCount = releasedCount
        self.closedPlanCount = closedPlanCount
    }
}

/// 终态完成单元的有界恢复工作器。
///
/// 轮询属于正确性路径而非单纯的唤醒提示：进程在投影阶段与释放阶段之间崩溃时，
/// 重启后会通过轮询补上未完成的释放。
public struct V2FanoutCompletionReleaseWorker: Sendable {
    private let store: any V2FanoutCompletionReleaseStore
    private let now: @Sendable () -> Date

    /// 组合释放存储与授时来源。
    ///
    /// - Parameters:
    ///   - store: 实际执行释放的存储实现。
    ///   - now: 可注入的当前时刻读取函数。
    public init(
        store: any V2FanoutCompletionReleaseStore,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.now = now
    }

    /// 执行一轮有界释放。
    ///
    /// - Parameter limit: 本轮最多处理的工作单元数，需大于零。
    /// - Returns: 本轮释放统计。
    /// - Throws: 任务已取消时抛出 `CancellationError`；其余错误来自存储实现。
    public func runOnce(limit: Int) async throws -> V2FanoutCompletionReleaseReport {
        precondition(limit > 0)
        try Task.checkCancellation()
        return try await store.releaseTerminalCompletionUnits(now: now(), limit: limit)
    }
}
