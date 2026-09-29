import IMV2ServerContracts
import Foundation
import IMV2Core

/// 单轮同步维护统计。
public struct V2SyncHousekeepingReport: Equatable, Sendable {
    /// 清理的过期同步令牌数量。
    public let expiredTokenCount: Int
    /// 清理的过期回执数量。
    public let expiredReceiptCount: Int
    /// 从过期暂存重置中恢复的设备数量。
    public let recoveredResetCount: Int
    /// 清理的快照产物数量。
    public let purgedSnapshotCount: Int
    /// 清理的投影效果记录数量。
    public let purgedProjectionEffectCount: Int

    /// 保存维护统计。
    ///
    /// - Parameters:
    ///   - expiredTokenCount: 过期令牌数量。
    ///   - expiredReceiptCount: 过期回执数量。
    ///   - recoveredResetCount: 恢复重置的设备数量。
    ///   - purgedSnapshotCount: 清理快照数量。
    ///   - purgedProjectionEffectCount: 清理投影效果数量，默认零。
    public init(
        expiredTokenCount: Int,
        expiredReceiptCount: Int,
        recoveredResetCount: Int,
        purgedSnapshotCount: Int,
        purgedProjectionEffectCount: Int = 0
    ) {
        self.expiredTokenCount = expiredTokenCount
        self.expiredReceiptCount = expiredReceiptCount
        self.recoveredResetCount = recoveredResetCount
        self.purgedSnapshotCount = purgedSnapshotCount
        self.purgedProjectionEffectCount = purgedProjectionEffectCount
    }

    /// 本轮是否产生了实际清理或恢复。
    public var didWork: Bool {
        expiredTokenCount > 0 || expiredReceiptCount > 0 ||
            recoveredResetCount > 0 || purgedSnapshotCount > 0 ||
            purgedProjectionEffectCount > 0
    }
}

/// 同步维护的持久化能力。
public protocol V2SyncHousekeepingStore: Sendable {
    /// 清理过期状态并恢复可用的暂存重置。
    ///
    /// - Parameters:
    ///   - now: 本次判定的服务端时刻。
    ///   - projectionEffectRetention: 投影效果记录的最短保留时长。
    ///   - limit: 本轮最多处理的数量。
    /// - Returns: 本轮维护统计。
    /// - Throws: 持久化失败时抛出。
    func purgeExpired(
        now: Date,
        projectionEffectRetention: TimeInterval,
        limit: Int
    ) async throws -> V2SyncHousekeepingReport
}

/// 同步维护工作器。
public struct V2SyncHousekeepingWorker: Sendable {
    private let store: any V2SyncHousekeepingStore
    private let projectionEffectRetention: TimeInterval
    private let now: @Sendable () -> Date

    /// 组合维护存储与保留策略。
    ///
    /// - Parameters:
    ///   - store: 执行清理的持久化存储。
    ///   - projectionEffectRetention: 投影效果保留秒数，默认取幂等策略的最短保留期。
    ///   - now: 可注入的当前时刻读取函数。
    ///
    /// 保留期非有限或短于幂等策略下限时直接失败，避免过早清理造成重复投递。
    public init(
        store: any V2SyncHousekeepingStore,
        projectionEffectRetention: TimeInterval = V2IdempotencyPolicy.minimumServerRetention,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(
            projectionEffectRetention.isFinite &&
                projectionEffectRetention >= V2IdempotencyPolicy.minimumServerRetention
        )
        self.store = store
        self.projectionEffectRetention = projectionEffectRetention
        self.now = now
    }

    /// 执行一轮有界同步维护。
    ///
    /// - Parameter limit: 本轮最多处理的数量，需大于零。
    /// - Returns: 本轮维护统计。
    /// - Throws: 上限非正时抛出 ``V2SyncHousekeepingError/invalidLimit``；
    ///   其余错误来自存储实现。
    public func runOnce(limit: Int) async throws -> V2SyncHousekeepingReport {
        guard limit > 0 else { throw V2SyncHousekeepingError.invalidLimit }
        return try await store.purgeExpired(
            now: now(),
            projectionEffectRetention: projectionEffectRetention,
            limit: limit
        )
    }
}

/// 同步维护错误。
public enum V2SyncHousekeepingError: Error, Equatable, Sendable {
    /// 单轮上限为非正值。
    case invalidLimit
    /// 持久化状态损坏。
    case corruptPersistenceState
}
