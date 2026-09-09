import Foundation

/// 运行时驱动可靠同步所需的最小接口。
///
/// 具体引擎拥有跨拉取、应用和确认的串行控制，测试可注入替身而无需建立数据库或帧连接。
public protocol V2SyncDriving: Sendable {
    /// 追赶增量直至没有更多页面或遇到快照恢复需求；接口不规定固定页数预算，错误通过抛出报告。
    func synchronizeUntilCaughtUp() async throws -> V2SyncCycleResult
    /// 完成当前持久化的快照恢复流程；成功后才允许基于新投影执行后续工作，失败通过抛出报告。
    func completePendingReset() async throws
}

/// 消费在线可用性提示并驱动同步的运行循环。
///
/// 应用拥有调用 run 的任务，通过前后台策略控制生命周期。提示只触发正常拉取与确认，不是持久化投递凭据。
/// 本类型不实现提示合并、周期补拉或页数预算，提示合并由来源实现负责。
public struct V2AvailabilityDrivenSyncRunner: Sendable {
    /// 单消费者提示来源，负责等待下一次可能有新数据的唤醒。
    private let source: any V2SyncAvailabilityHintSource
    /// 执行增量追赶及快照恢复的引擎。
    private let syncEngine: any V2SyncDriving
    /// 同步及必要的快照恢复成功后执行的工作，例如由组装层注入有界房间扫描。
    private let afterSynchronization: @Sendable () async throws -> Void

    /// 配置提示驱动循环，不创建运行任务。
    ///
    /// - Parameters:
    ///   - source: 由当前运行循环独占消费的提示来源。
    ///   - syncEngine: 可靠同步驱动实现。
    ///   - afterSynchronization: 同步成功后的异步操作，默认无操作；任务所有者负责定义其预算与重试策略。
    public init(
        source: any V2SyncAvailabilityHintSource,
        syncEngine: any V2SyncDriving,
        afterSynchronization: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.source = source
        self.syncEngine = syncEngine
        self.afterSynchronization = afterSynchronization
    }

    /// 逐个等待提示，追赶同步并执行后续工作，直到取消或出错。
    ///
    /// - Throws: 提示来源、同步、快照恢复、取消检查或后续操作错误，均结束本轮运行并向上抛出。
    ///
    /// 提示内容在此被忽略，真实状态由同步引擎重新读取。增量返回 resetPending 时先完成恢复，
    /// 避免后续工作读取尚未切换的旧投影；完成后不会立即再次追赶增量，而是执行后续闭包并等待下一次提示。
    ///
    /// 进入循环时若已取消则正常返回；提示返回后不额外检查取消，取消响应依赖同步实现，后续闭包之前有显式检查。
    /// 本方法没有定时唤醒，也不在内部自动重启失败循环。
    public func run() async throws {
        while !Task.isCancelled {
            _ = try await source.nextAvailabilityHint()
            if case .resetPending = try await syncEngine.synchronizeUntilCaughtUp() {
                // A reset can be requested at any time, not only during the
                // initial connection catch-up. Do not run post-sync effects
                // against the fenced pre-reset projection.
                try await syncEngine.completePendingReset()
            }
            try Task.checkCancellation()
            try await afterSynchronization()
        }
    }
}
