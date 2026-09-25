import Foundation
import IMV2Core

/// 一次转发媒体导入的租约。
public struct V2ForwardMediaImportLease: Sendable {
    /// 本次导入的不可变导出内容。
    public let export: V2ForwardExport
    /// 媒体在导出清单中的下标。
    public let ordinal: Int
    /// 目标侧媒体标识。
    public let targetMediaID: MediaID
    /// 目标侧上传会话标识。
    public let targetUploadSessionID: UUID
    /// 已持久化的复制摘要；为空表示尚未复制成功。
    public let copiedDigest: Data?
    /// 本次租约的认领令牌。
    public let claimToken: UUID
    /// 本次是第几次尝试。
    public let attempt: Int
    /// 租约到期时刻。
    public let expiresAt: Date

    /// 导出清单中对应的媒体条目。
    public var source: V2ForwardExportMedia { export.intent.media[ordinal] }
}

/// 一次媒体复制的回执。
public struct V2ForwardMediaCopyReceipt: Equatable, Sendable {
    /// 实际复制的字节数。
    public let byteCount: Int64
    /// 复制内容的 SHA-256 摘要。
    public let digest: Data

    /// 校验并保存复制回执。
    ///
    /// - Parameters:
    ///   - byteCount: 复制的字节数，需大于零。
    ///   - digest: 复制摘要，需为 32 字节。
    /// - Throws: 任一约束不满足时抛出
    ///   ``V2ForwardMediaCopyError/invalidReceipt``。
    public init(byteCount: Int64, digest: Data) throws {
        guard byteCount > 0, digest.count == 32 else { throw V2ForwardMediaCopyError.invalidReceipt }
        self.byteCount = byteCount; self.digest = digest
    }
}

/// 提供方负责的字节 I/O，在所有数据库事务之外执行。
///
/// 安装过程绝不能覆盖不同的对象；重试时要么用已持久化的复制摘要校验现有对象，
/// 要么重新生成完全相同的字节。
public protocol V2ForwardMediaObjectCopying: Sendable {
    /// 执行一次媒体对象复制。
    ///
    /// - Parameter lease: 本次导入租约。
    /// - Returns: 复制回执。
    /// - Throws: 复制失败或校验不通过时抛出。
    func copy(_ lease: V2ForwardMediaImportLease) async throws -> V2ForwardMediaCopyReceipt
}

/// 转发媒体复制错误。
public enum V2ForwardMediaCopyError: Error, Equatable, Sendable {
    /// 复制回执或配置参数非法。
    case invalidReceipt
    /// 实际字节数与清单不符。
    case byteCountMismatch
    /// 目标对象已存在且内容不同。
    case contentConflict
    /// 超出允许的单对象大小上限。
    case sizeLimitExceeded
    /// 来源对象当前不可用。
    case sourceUnavailable
}

/// 单次转发媒体导入的结论。
public enum V2ForwardMediaImportOutcome: Equatable, Sendable {
    /// 当前没有可处理的工作。
    case idle
    /// 媒体已复制、扫描通过，可供目标消息引用。
    case ready
    /// 媒体确定不可用，导入被拒绝。
    case rejected
    /// 已安排后续重试。
    case retryScheduled
    /// 重试次数耗尽，已暂停等待运维重放。
    case paused
    /// 本次租约已被更新的认领取代。
    case superseded
}

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
