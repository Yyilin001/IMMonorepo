import Foundation
import IMV2Core

/// 媒体清理原因。
public enum V2MediaPurgeReason: String, Equatable, Sendable {
    /// 对象已过期且不再被任何消息引用。
    case unreferencedExpired = "unreferenced_expired"
    /// 引用该对象的消息均已超过撤回保留期。
    case withdrawnRetentionElapsed = "withdrawn_retention_elapsed"
}

/// 一次媒体清理租约。
public struct V2MediaPurgeLease: Equatable, Sendable {
    /// 目标媒体标识。
    public let mediaID: MediaID
    /// 进入清理队列的原因。
    public let reason: V2MediaPurgeReason
    /// 本次租约的认领令牌。
    public let claimToken: UUID
    /// 本次是第几次尝试。
    public let attempt: Int

    /// 构造清理租约。
    ///
    /// - Parameters:
    ///   - mediaID: 目标媒体标识。
    ///   - reason: 清理原因。
    ///   - claimToken: 认领令牌。
    ///   - attempt: 尝试次数，需大于零。
    ///
    /// 尝试次数非正时直接失败，避免重试退避从非法状态开始。
    public init(mediaID: MediaID, reason: V2MediaPurgeReason, claimToken: UUID, attempt: Int = 1) {
        precondition(attempt > 0)
        self.mediaID = mediaID
        self.reason = reason
        self.claimToken = claimToken
        self.attempt = attempt
    }
}

/// 媒体清理提供方边界。
///
/// 提供方负责把不透明媒体标识映射到其私有对象位置；聊天工作器不会收到对象键、地址或凭据。
public protocol V2MediaPurgeProvider: Sendable {
    /// 清理指定媒体的提供方对象。
    ///
    /// - Parameter mediaID: 目标媒体标识。
    /// - Throws: 提供方失败时抛出，调用方据此安排重试。
    func purge(mediaID: MediaID) async throws
}

/// 媒体清理任务的持久化能力。
public protocol V2MediaPurgeStore: Sendable {
    /// 认领一批待清理媒体。
    ///
    /// - Parameters:
    ///   - now: 本次认领时刻。
    ///   - leaseDuration: 租约时长秒数。
    ///   - limit: 本次最多认领的数量。
    /// - Returns: 认领到的清理租约。
    /// - Throws: 持久化失败时抛出。
    func claimPending(now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2MediaPurgeLease]

    /// 记录清理完成。
    ///
    /// - Parameters:
    ///   - lease: 本次清理租约。
    ///   - now: 完成时刻。
    /// - Throws: 持久化失败时抛出。
    func markCompleted(_ lease: V2MediaPurgeLease, now: Date) async throws

    /// 按处置结果安排重试或暂停。
    ///
    /// - Parameters:
    ///   - lease: 本次清理租约。
    ///   - disposition: 下一步处置。
    ///   - now: 记录时刻。
    /// - Throws: 持久化失败时抛出。
    func scheduleRetry(_ lease: V2MediaPurgeLease, disposition: V2DurableRetryDisposition, now: Date) async throws
}

/// 单轮媒体清理统计。
public struct V2MediaPurgeReport: Equatable, Sendable {
    /// 本轮认领数量。
    public let claimedCount: Int
    /// 完成清理的数量。
    public let completedCount: Int
    /// 安排重试的数量。
    public let releasedCount: Int
    /// 暂停等待运维处理的数量。
    public let pausedCount: Int

    /// 保存清理统计。
    ///
    /// - Parameters:
    ///   - claimedCount: 认领数量。
    ///   - completedCount: 完成数量。
    ///   - releasedCount: 安排重试数量。
    ///   - pausedCount: 暂停数量，默认零。
    public init(claimedCount: Int, completedCount: Int, releasedCount: Int, pausedCount: Int = 0) {
        self.claimedCount = claimedCount
        self.completedCount = completedCount
        self.releasedCount = releasedCount
        self.pausedCount = pausedCount
    }
}

/// 有界且至少执行一次的媒体清理工作器。
///
/// 提供方报错时只有这条清理发件箱条目可重试，不会让聊天侧的媒体终态被重新激活。
public struct V2MediaPurgeWorker: Sendable {
    private let store: any V2MediaPurgeStore
    private let provider: any V2MediaPurgeProvider
    private let leaseDuration: TimeInterval
    private let retryPolicy: V2DurableRetryPolicy
    private let maximumConcurrency: Int
    private let now: @Sendable () -> Date

    /// 组合清理存储、提供方与并发参数。
    ///
    /// - Parameters:
    ///   - store: 清理任务的持久化存储。
    ///   - provider: 执行对象清理的提供方。
    ///   - leaseDuration: 租约时长秒数，需大于零。
    ///   - retryPolicy: 失败退避策略。
    ///   - maximumConcurrency: 并发上限，需大于零。
    ///   - now: 可注入的当前时刻读取函数。
    /// - Throws: 租约时长非正时抛出
    ///   ``V2MediaPurgeWorkerError/invalidLeaseDuration``；并发非正时抛出
    ///   ``V2MediaPurgeWorkerError/invalidMaximumConcurrency``。
    public init(store: any V2MediaPurgeStore, provider: any V2MediaPurgeProvider, leaseDuration: TimeInterval = 30, retryPolicy: V2DurableRetryPolicy = .standard, maximumConcurrency: Int = 4, now: @escaping @Sendable () -> Date = Date.init) throws {
        guard leaseDuration > 0 else { throw V2MediaPurgeWorkerError.invalidLeaseDuration }
        guard maximumConcurrency > 0 else { throw V2MediaPurgeWorkerError.invalidMaximumConcurrency }
        self.store = store
        self.provider = provider
        self.leaseDuration = leaseDuration
        self.retryPolicy = retryPolicy
        self.maximumConcurrency = maximumConcurrency
        self.now = now
    }

    /// 执行一轮有界清理。
    ///
    /// 认领到的租约按并发上限分批处理；提供方失败会按重试策略安排重试或暂停，
    /// 任务取消则向上传播。
    ///
    /// - Parameter limit: 本轮最多认领的媒体数，需大于零。
    /// - Returns: 本轮清理统计。
    /// - Throws: 上限非正时抛出 ``V2MediaPurgeWorkerError/invalidLimit``；
    ///   任务取消时抛出 `CancellationError`；重试时刻不晚于当前时刻时抛出
    ///   ``V2RoomWriteStoreError/corruptPersistenceState``。
    public func runOnce(limit: Int) async throws -> V2MediaPurgeReport {
        guard limit > 0 else { throw V2MediaPurgeWorkerError.invalidLimit }
        let leases = try await store.claimPending(now: now(), leaseDuration: leaseDuration, limit: limit)
        var outcomes: [V2MediaPurgeWorkOutcome] = []
        for start in stride(from: 0, to: leases.count, by: maximumConcurrency) {
            let end = Swift.min(start + maximumConcurrency, leases.count)
            let batch = Array(leases[start..<end])
            let batchOutcomes = try await withThrowingTaskGroup(
                of: V2MediaPurgeWorkOutcome.self,
                returning: [V2MediaPurgeWorkOutcome].self
            ) { group in
                for lease in batch {
                    group.addTask {
                        do {
                            try await self.provider.purge(mediaID: lease.mediaID)
                            try await self.store.markCompleted(lease, now: self.now())
                            return .completed
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            let failureTime = self.now()
                            let disposition = self.retryPolicy.disposition(
                                attempt: lease.attempt,
                                claimToken: lease.claimToken,
                                now: failureTime
                            )
                            if case .retry(let retryAt) = disposition, !v2PostgresTimestampPrecedes(failureTime, retryAt) {
                                throw V2RoomWriteStoreError.corruptPersistenceState
                            }
                            try await self.store.scheduleRetry(lease, disposition: disposition, now: failureTime)
                            return disposition.isPause ? .paused : .released
                        }
                    }
                }
                var values: [V2MediaPurgeWorkOutcome] = []
                for try await value in group { values.append(value) }
                return values
            }
            outcomes.append(contentsOf: batchOutcomes)
        }
        return .init(
            claimedCount: leases.count,
            completedCount: outcomes.count(where: { $0 == .completed }),
            releasedCount: outcomes.count(where: { $0 == .released }),
            pausedCount: outcomes.count(where: { $0 == .paused })
        )
    }
}

/// 媒体清理工作器错误。
public enum V2MediaPurgeWorkerError: Error, Equatable, Sendable {
    /// 租约时长非正。
    case invalidLeaseDuration
    /// 单轮上限非正。
    case invalidLimit
    /// 并发上限非正。
    case invalidMaximumConcurrency
}

/// 批量清理过程中的单个结果分类。
private enum V2MediaPurgeWorkOutcome: Equatable, Sendable { case completed, released, paused }

private extension V2DurableRetryDisposition {
    /// 该处置是否为暂停。
    var isPause: Bool {
        if case .pause = self { return true }
        return false
    }
}
