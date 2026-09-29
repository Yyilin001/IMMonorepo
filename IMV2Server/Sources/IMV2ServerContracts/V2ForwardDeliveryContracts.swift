import Foundation
import IMV2Core
import IMV2ActorContracts

/// 受信的目标归属边界。
///
/// 返回 `nil` 只表示目标侧的持久化工作仍未完成，绝不表示已拒绝、已完成或可以释放源端置顶占用。
public protocol V2ForwardExportDelivering: Sendable {
    // 实现必须传播取消并限制底层 I/O 时长；
    // 工作器释放认领前会取消并等待此调用结束。
    func deliver(_ export: V2ForwardExport) async throws -> V2ForwardTerminalReceipt?
}

/// 转发投递错误。
public enum V2ForwardDeliveryError: Error, Equatable, Sendable {
    /// 投递配置参数非法。
    case invalidConfiguration
    /// 目标归属当前不可用。
    case targetUnavailable
    /// 媒体导入已暂停，需等待运维重放。
    case mediaPaused
    /// 目标返回的回执与本次导出不一致。
    case receiptMismatch
    /// 目标投递超出允许时长。
    case timedOut
}

/// 单轮投递统计。
public struct V2ForwardDeliveryReport: Equatable, Sendable {
    package init() {}
    /// 本轮认领数量。
    public var claimed = 0
    /// 完成数量。
    public var completed = 0
    /// 因目标仍在处理而延后的数量。
    public var deferred = 0
    /// 安排重试的数量。
    public var retried = 0
    /// 暂停等待运维重放的数量。
    public var paused = 0
    /// 因租约被取代而放弃的数量。
    public var superseded = 0
}


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

    package init(export: V2ForwardExport, ordinal: Int, targetMediaID: MediaID,
                 targetUploadSessionID: UUID, copiedDigest: Data?, claimToken: UUID,
                 attempt: Int, expiresAt: Date) {
        self.export = export; self.ordinal = ordinal; self.targetMediaID = targetMediaID
        self.targetUploadSessionID = targetUploadSessionID; self.copiedDigest = copiedDigest
        self.claimToken = claimToken; self.attempt = attempt; self.expiresAt = expiresAt
    }

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


/// 跨归属转发在源端等待结果时出现的瞬时错误。
public enum V2ForwardPendingError: Error, Equatable, Sendable { case pending, paused }

/// 跨归属转发的调用结果。
public enum V2CrossOwnerForwardOutcome: Sendable {
    /// 已得到终态结果。
    case completed(V2ForwardMessageResult)
    /// 仍在进行中，`paused` 表示源端投递已被暂停等待运维重放。
    case pending(paused: Bool)
}

/// 跨房间归属的转发能力。
public protocol V2CrossOwnerForwarding: Sendable {
    /// 把源房间的消息转发到目标房间。
    ///
    /// - Parameters:
    ///   - actor: 发起转发的用户。
    ///   - operation: 转发的幂等操作标识。
    ///   - source: 源消息引用。
    ///   - sourceRoute: 源房间的已选定归属。
    ///   - target: 目标房间。
    ///   - targetRoute: 目标房间的已选定归属。
    /// - Returns: 终态结果或仍在等待的状态。
    /// - Throws: 源归属未配置或持久化失败时抛出。
    func forward(actor: UserID, operation: MessageForwardOperationID, source: V2ForwardMessageReference,
                 sourceRoute: V2RoomShardRoute, target: RoomID, targetRoute: V2RoomShardRoute) async throws -> V2CrossOwnerForwardOutcome
    func forward(actor: UserID, operation: MessageForwardOperationID, source: V2ForwardMessageReference,
                 sourceRoute: V2RoomShardRoute, target: RoomID, targetRoute: V2RoomShardRoute,
                 deadline: ContinuousClock.Instant) async throws -> V2CrossOwnerForwardOutcome
}

extension V2CrossOwnerForwarding {
    public func forward(actor: UserID, operation: MessageForwardOperationID, source: V2ForwardMessageReference,
                        sourceRoute: V2RoomShardRoute, target: RoomID, targetRoute: V2RoomShardRoute,
                        deadline: ContinuousClock.Instant) async throws -> V2CrossOwnerForwardOutcome {
        guard ContinuousClock().now < deadline else {
            throw V2RoomCallFailure.notAccepted(.deadlineExceeded)
        }
        return try await forward(actor: actor, operation: operation, source: source,
            sourceRoute: sourceRoute, target: target, targetRoute: targetRoute)
    }
}


/// 转发消息的对外处理能力。
public protocol V2ForwardMessagesHandling: Sendable {
    /// 执行一次可能包含多个目标房间的转发。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起转发的用户。
    ///   - command: 转发命令。
    /// - Returns: 与源消息和目标房间组合对应的结果列表。
    /// - Throws: 归属不匹配、授权不足或持久化失败时抛出。
    func forward(actorUserID: UserID, command: V2ForwardMessagesCommand) async throws -> [V2ForwardMessageResult]
}


public enum V2ForwardExportPreparation: Sendable {
    case export(V2ForwardExport)
    case terminal(V2ForwardImportOutcome)
}
/// Reads committed source receipts without exposing database handles.
public protocol V2ForwardReceiptReading: Sendable {
    func terminalStatus(actor: UserID, operation: MessageForwardOperationID,
                        source: V2ForwardMessageReference, target: RoomID) async throws -> V2ForwardImportOutcome?
    func status(exportID: UUID) async throws -> V2ForwardImportOutcome?
}

public protocol V2ForwardDeliveryStatusReading: Sendable {
    func isPaused(exportID: UUID) async throws -> Bool
}

public protocol V2ForwardExportPreparing: Sendable {
    func prepareForDelivery(actorUserID: UserID, operationID: MessageForwardOperationID,
                            source: V2ForwardMessageReference, sourceRoute: V2RoomShardRoute,
                            targetRoomID: RoomID, targetRoute: V2RoomShardRoute,
                            now: Date) async throws -> V2ForwardExportPreparation
}

public protocol V2ForwardTerminalReceiptReading: Sendable {
    func terminalReceipt(exportID: UUID) async throws -> V2ForwardTerminalReceipt?
}

public protocol V2ForwardMediaImportRunning: Sendable {
    func runOnce(exportID: UUID) async throws -> V2ForwardMediaImportOutcome
}

/// Imports an export using the target owner's configured acceptance path.
public protocol V2ForwardExportImporting: Sendable {
    func importForwardExport(_ export: V2ForwardExport, capacityProfile: V2CapacityProfile,
                             limits: V2MessageCommandLimits, identifiers: V2AcceptanceIdentifiers,
                             now: Date) async throws -> V2ForwardImportOutcome
}
