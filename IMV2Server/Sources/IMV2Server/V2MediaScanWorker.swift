import Foundation
import IMV2Core

/// 媒体扫描结论。
public enum V2MediaScanResult: Equatable, Sendable {
    /// 扫描通过。
    case passed
    /// 扫描不通过。
    case failed
}

/// 一次媒体扫描的租约。
public struct V2MediaScanLease: Equatable, Sendable {
    /// 目标媒体标识。
    public let mediaID: MediaID
    /// 本次租约的认领令牌。
    public let claimToken: UUID
    /// 本次是第几次尝试。
    public let attempt: Int

    /// 构造扫描租约。
    ///
    /// - Parameters:
    ///   - mediaID: 目标媒体标识。
    ///   - claimToken: 认领令牌。
    ///   - attempt: 尝试次数，需大于零。
    ///
    /// 尝试次数非正时直接失败，避免重试退避从非法状态开始。
    public init(mediaID: MediaID, claimToken: UUID, attempt: Int = 1) {
        precondition(attempt > 0)
        self.mediaID = mediaID
        self.claimToken = claimToken
        self.attempt = attempt
    }
}

/// 扫描提供方边界。
///
/// 提供方私有的对象身份解析留在该边界之后；聊天工作器只传入不透明媒体标识，
/// 不会收到字节内容、文件名、哈希、缩略图、对象键或提供方凭据。
public protocol V2MediaScanProvider: Sendable {
    /// 扫描指定媒体。
    ///
    /// - Parameter mediaID: 目标媒体标识。
    /// - Returns: 扫描结论。
    /// - Throws: 提供方失败时抛出。
    func scan(mediaID: MediaID) async throws -> V2MediaScanResult
}

/// 媒体扫描任务的持久化能力。
public protocol V2MediaScanStore: Sendable {
    /// 认领一批待扫描媒体。
    ///
    /// - Parameters:
    ///   - now: 本次认领时刻。
    ///   - leaseDuration: 租约时长秒数。
    ///   - limit: 本次最多认领的数量。
    /// - Returns: 认领到的扫描租约。
    /// - Throws: 持久化失败时抛出。
    func claimPending(now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2MediaScanLease]

    /// 记录扫描结论并推进媒体状态。
    ///
    /// - Parameters:
    ///   - lease: 本次扫描租约。
    ///   - result: 扫描结论。
    ///   - now: 完成时刻。
    /// - Throws: 持久化失败时抛出。
    func complete(_ lease: V2MediaScanLease, result: V2MediaScanResult, now: Date) async throws

    /// 按处置结果安排重试或暂停。
    ///
    /// - Parameters:
    ///   - lease: 本次扫描租约。
    ///   - disposition: 下一步处置。
    ///   - now: 记录时刻。
    /// - Throws: 持久化失败时抛出。
    func scheduleRetry(_ lease: V2MediaScanLease, disposition: V2DurableRetryDisposition, now: Date) async throws
}

/// 单轮媒体扫描统计。
public struct V2MediaScanReport: Equatable, Sendable {
    /// 本轮认领数量。
    public let claimedCount: Int
    /// 完成扫描的数量。
    public let completedCount: Int
    /// 安排重试的数量。
    public let releasedCount: Int
    /// 暂停等待运维处理的数量。
    public let pausedCount: Int

    /// 保存扫描统计。
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

/// 有界媒体扫描工作器。
///
/// 提供方失败不会让媒体变为可引用：发件箱条目会被重试，而媒体对象保持 `scanning` 状态。
public struct V2MediaScanWorker: Sendable {
    private let store: any V2MediaScanStore
    private let provider: any V2MediaScanProvider
    private let leaseDuration: TimeInterval
    private let retryPolicy: V2DurableRetryPolicy
    private let maximumConcurrency: Int
    private let now: @Sendable () -> Date

    /// 组合扫描存储、提供方与并发参数。
    ///
    /// - Parameters:
    ///   - store: 扫描任务的持久化存储。
    ///   - provider: 执行扫描的提供方。
    ///   - leaseDuration: 租约时长秒数，需大于零。
    ///   - retryPolicy: 失败退避策略。
    ///   - maximumConcurrency: 并发上限，需大于零。
    ///   - now: 可注入的当前时刻读取函数。
    /// - Throws: 租约时长非正时抛出
    ///   ``V2MediaScanWorkerError/invalidLeaseDuration``；并发非正时抛出
    ///   ``V2MediaScanWorkerError/invalidMaximumConcurrency``。
    public init(store: any V2MediaScanStore, provider: any V2MediaScanProvider, leaseDuration: TimeInterval = 30, retryPolicy: V2DurableRetryPolicy = .standard, maximumConcurrency: Int = 4, now: @escaping @Sendable () -> Date = Date.init) throws {
        guard leaseDuration > 0 else { throw V2MediaScanWorkerError.invalidLeaseDuration }
        guard maximumConcurrency > 0 else { throw V2MediaScanWorkerError.invalidMaximumConcurrency }
        self.store = store
        self.provider = provider
        self.leaseDuration = leaseDuration
        self.retryPolicy = retryPolicy
        self.maximumConcurrency = maximumConcurrency
        self.now = now
    }

    /// 执行一轮有界扫描。
    ///
    /// 认领到的租约按并发上限分批处理；提供方失败会按重试策略安排重试或暂停，
    /// 任务取消则向上传播并让运行时的正常取消语义接管。
    ///
    /// - Parameter limit: 本轮最多认领的媒体数，需大于零。
    /// - Returns: 本轮扫描统计。
    /// - Throws: 上限非正时抛出 ``V2MediaScanWorkerError/invalidLimit``；
    ///   任务取消时抛出 `CancellationError`；重试时刻不晚于当前时刻时抛出
    ///   ``V2RoomWriteStoreError/corruptPersistenceState``。
    public func runOnce(limit: Int) async throws -> V2MediaScanReport {
        guard limit > 0 else { throw V2MediaScanWorkerError.invalidLimit }
        let leases = try await store.claimPending(now: now(), leaseDuration: leaseDuration, limit: limit)
        var outcomes: [V2MediaWorkOutcome] = []
        for start in stride(from: 0, to: leases.count, by: maximumConcurrency) {
            let end = Swift.min(start + maximumConcurrency, leases.count)
            let batch = Array(leases[start..<end])
            let batchOutcomes = try await withThrowingTaskGroup(
                of: V2MediaWorkOutcome.self,
                returning: [V2MediaWorkOutcome].self
            ) { group in
                for lease in batch {
                    group.addTask {
                        do {
                            let result = try await self.provider.scan(mediaID: lease.mediaID)
                            try await self.store.complete(lease, result: result, now: self.now())
                            return .completed
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            let failureTime = self.now()
                            let disposition = self.retryPolicy.disposition(
                                attempt: lease.attempt,
                                claimToken: lease.claimToken,
                                now: failureTime,
                                kind: v2DurableWorkFailureKind(for: error)
                            )
                            if case .retry(let retryAt) = disposition, !v2PostgresTimestampPrecedes(failureTime, retryAt) {
                                throw V2RoomWriteStoreError.corruptPersistenceState
                            }
                            try await self.store.scheduleRetry(lease, disposition: disposition, now: failureTime)
                            return disposition.isPause ? .paused : .released
                        }
                    }
                }
                var values: [V2MediaWorkOutcome] = []
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

/// 媒体扫描工作器错误。
public enum V2MediaScanWorkerError: Error, Equatable, Sendable {
    /// 租约时长非正。
    case invalidLeaseDuration
    /// 单轮上限非正。
    case invalidLimit
    /// 并发上限非正。
    case invalidMaximumConcurrency
}

/// 批量扫描过程中的单个结果分类。
private enum V2MediaWorkOutcome: Equatable, Sendable { case completed, released, paused }

private extension V2DurableRetryDisposition {
    /// 该处置是否为暂停。
    var isPause: Bool {
        if case .pause = self { return true }
        return false
    }
}
