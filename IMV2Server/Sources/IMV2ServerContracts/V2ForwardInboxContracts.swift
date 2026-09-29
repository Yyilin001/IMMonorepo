import Foundation
import IMV2Core

/// 转发导入仍未完成的原因。
public enum V2ForwardImportPendingReason: Equatable, Sendable {
    /// 仍在等待媒体就绪。
    case media
    /// 仍在等待目标准入额度。
    case admission
    /// 媒体与准入均已就绪，正在收尾提交。
    case finalization
}

/// 转发导入的结果。
public enum V2ForwardImportOutcome: Equatable, Sendable {
    /// 目标侧已接受，附带消息标识与房间序号。
    case accepted(messageID: MessageID, roomSequence: UInt64)
    /// 目标侧拒绝，附带稳定错误码。
    case rejected(code: String)
    /// 仍在处理中，附带原因。
    case pending(V2ForwardImportPendingReason)
}

/// 转发收件箱错误。
public enum V2ForwardInboxError: Error, Equatable, Sendable {
    /// 目标房间归属已变更。
    case ownerChanged
    /// 目标房间或收件箱记录不存在。
    case targetNotFound
    /// 同一幂等标识已被不同载荷占用。
    case idempotencyConflict
    /// 目标房间的未完成导入数量已达上限。
    case capacityExceeded
    /// 持久化记录缺失或字段无法解码。
    case corruptPersistenceState
}
