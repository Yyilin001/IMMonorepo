import Foundation

/// 调度提供方字节清理，但不把对象位置或 Bearer 凭据写入聊天数据库。
///
/// 提供方适配器单独消费由此产生的发件箱，其重试与聊天写入互不影响。
public protocol V2MediaRetentionStore: Sendable {
    /// 使符合过期条件的媒体进入待清理状态。
    ///
    /// - Parameters:
    ///   - now: 本次判定的服务端时刻。
    ///   - withdrawnRetention: 已撤回媒体在清理前保留的秒数。
    ///   - limit: 本次最多处理的条数。
    /// - Returns: 本次实际处理的条数。
    /// - Throws: 持久化失败时抛出。
    func expireEligibleMedia(now: Date, withdrawnRetention: TimeInterval, limit: Int) async throws -> Int
}

/// 周期运行的媒体保留清理工作器。
public struct V2MediaRetentionWorker: Sendable {
    private let store: any V2MediaRetentionStore
    private let now: @Sendable () -> Date
    private let withdrawnRetention: TimeInterval

    /// 组合保留存储与判定参数。
    ///
    /// - Parameters:
    ///   - store: 实际登记待清理项的存储。
    ///   - withdrawnRetention: 已撤回媒体的保留秒数，默认 30 天，需大于零。
    ///   - now: 可注入的当前时刻读取函数。
    /// - Throws: 保留时长非正时抛出
    ///   ``V2MediaRetentionWorkerError/invalidRetention``。
    public init(
        store: any V2MediaRetentionStore,
        withdrawnRetention: TimeInterval = 30 * 86_400,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard withdrawnRetention > 0 else { throw V2MediaRetentionWorkerError.invalidRetention }
        self.store = store
        self.withdrawnRetention = withdrawnRetention
        self.now = now
    }

    /// 执行一轮有界清理，便于作为可重试的周期任务运行。
    ///
    /// - Parameter limit: 本轮最多处理的条数，需大于零。
    /// - Returns: 本轮实际处理的条数。
    /// - Throws: `limit` 非正时抛出 ``V2MediaRetentionWorkerError/invalidLimit``；
    ///   其余错误来自存储实现。
    @discardableResult
    public func runOnce(limit: Int) async throws -> Int {
        guard limit > 0 else { throw V2MediaRetentionWorkerError.invalidLimit }
        return try await store.expireEligibleMedia(now: now(), withdrawnRetention: withdrawnRetention, limit: limit)
    }
}

/// 媒体保留清理工作器的配置与调用错误。
public enum V2MediaRetentionWorkerError: Error, Equatable, Sendable {
    /// 已撤回媒体的保留时长为非正值。
    case invalidRetention
    /// 单轮处理条数为非正值。
    case invalidLimit
}
