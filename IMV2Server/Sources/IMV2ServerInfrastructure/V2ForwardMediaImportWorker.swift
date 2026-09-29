import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core

/// 转发媒体导入工作器。
///
/// 每次调用只处理一个有界附件；跨导出的并发由外层导出投递工作器决定，
/// 本工作器自身不再嵌套任何并发池。
public struct V2ForwardMediaImportWorker: Sendable {
    private let store: PostgresV2ForwardMediaImportStore
    private let copier: any V2ForwardMediaObjectCopying
    private let scanner: any V2MediaScanProvider
    private let leaseDuration: TimeInterval
    private let retryPolicy: V2DurableRetryPolicy
    private let now: @Sendable () -> Date

    /// 组合导入存储、复制实现、扫描提供方与重试策略。
    ///
    /// - Parameters:
    ///   - store: 导入任务的持久化存储。
    ///   - copier: 执行对象字节复制的实现。
    ///   - scanner: 目标媒体的扫描提供方。
    ///   - leaseDuration: 租约时长秒数，需大于零且不超过 3600。
    ///   - retryPolicy: 失败退避策略，默认使用标准值。
    ///   - now: 可注入的当前时刻读取函数。
    /// - Throws: 租约时长越界时抛出
    ///   ``V2ForwardMediaCopyError/invalidReceipt``。
    public init(store: PostgresV2ForwardMediaImportStore, copier: any V2ForwardMediaObjectCopying,
                scanner: any V2MediaScanProvider, leaseDuration: TimeInterval = 300,
                retryPolicy: V2DurableRetryPolicy = .standard,
                now: @escaping @Sendable () -> Date = Date.init) throws {
        guard leaseDuration.isFinite, leaseDuration > 0, leaseDuration <= 3_600 else { throw V2ForwardMediaCopyError.invalidReceipt }
        self.store = store; self.copier = copier; self.scanner = scanner
        self.leaseDuration = leaseDuration; self.retryPolicy = retryPolicy; self.now = now
    }

    /// 推进指定导出的一轮媒体导入。
    ///
    /// 字节数不符、内容冲突与超出大小上限会被判为拒绝；任务取消不会清理目标对象，
    /// 因为更新的租约可能已安装或使用同一稳定对象。重试处置会先校验重试时刻确实晚于当前时刻。
    ///
    /// - Parameter exportID: 目标导出标识。
    /// - Returns: 本轮导入结论。
    /// - Throws: 任务取消时抛出 `CancellationError`；重试时刻不晚于当前时刻时抛出
    ///   ``V2ForwardInboxError/corruptPersistenceState``；其余错误来自存储实现。
    public func runOnce(exportID: UUID) async throws -> V2ForwardMediaImportOutcome {
        guard let lease = try await store.claim(exportID: exportID, now: now(), leaseDuration: leaseDuration) else {
            // 上一个进程可能已经暂停并丢失响应。报告持久状态，
            // 避免来源投递一直将其视为空闲并轮询。
            return try await store.hasPausedImport(exportID: exportID) ? .paused : .idle
        }
        do {
            try Task.checkCancellation()
            let copied = try await copier.copy(lease)
            guard copied.byteCount == lease.source.byteCount else { throw V2ForwardMediaCopyError.byteCountMismatch }
            guard try await store.recordCopied(lease, receipt: copied, now: now()) else { return .superseded }
            try Task.checkCancellation()
            let result = try await scanner.scan(mediaID: lease.targetMediaID)
            try Task.checkCancellation()
            guard try await store.complete(lease, receipt: copied, result: result, now: now()) else { return .superseded }
            return result == .passed ? .ready : .rejected
        } catch is CancellationError {
            // 不要清除：更新的租约可能已安装或使用同一个稳定目标对象。
            // 取消时只释放当前操作持有的资源。
            _ = try? await store.retry(lease, disposition: .retry(at: now()), now: now())
            throw CancellationError()
        } catch V2ForwardMediaCopyError.contentConflict {
            return try await reject(lease)
        } catch V2ForwardMediaCopyError.byteCountMismatch {
            return try await reject(lease)
        } catch V2ForwardMediaCopyError.sizeLimitExceeded {
            return try await reject(lease)
        } catch {
            let failedAt = now()
            let disposition = retryPolicy.disposition(
                attempt: lease.attempt,
                claimToken: lease.claimToken,
                now: failedAt,
                kind: v2DurableWorkFailureKind(for: error)
            )
            if case .retry(let retryAt) = disposition, !v2PostgresTimestampPrecedes(failedAt, retryAt) {
                throw V2ForwardInboxError.corruptPersistenceState
            }
            guard try await store.retry(lease, disposition: disposition, now: failedAt) else { return .superseded }
            switch disposition {
            case .pause: return .paused
            case .retry: return .retryScheduled
            }
        }
    }

    /// 把租约标记为拒绝，返回对应结论。
    ///
    /// - Parameter lease: 本次导入租约。
    /// - Returns: 拒绝结论；租约已失效时返回被取代。
    /// - Throws: 存储写入失败时抛出。
    private func reject(_ lease: V2ForwardMediaImportLease) async throws -> V2ForwardMediaImportOutcome {
        try await store.reject(lease, now: now()) ? .rejected : .superseded
    }
}
