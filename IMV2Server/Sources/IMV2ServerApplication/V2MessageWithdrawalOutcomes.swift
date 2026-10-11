import IMV2ServerContracts
import Foundation
import IMV2Core

/// 消息撤回的执行结果。
public enum V2MessageWithdrawalOutcome: Equatable, Sendable {
    /// 本次调用实际提交了撤回。
    case withdrawn(V2MessageWithdrawal)
    /// 同一操作标识已撤回该消息，返回其原有结果。
    case idempotent(V2MessageWithdrawal)
    /// 同一操作标识已被不同载荷的命令占用。
    case idempotencyConflict
    /// 消息修订与期望值不符，参数为当前修订。
    case revisionConflict(current: UInt64)
    /// 消息此前已被撤回。
    case alreadyWithdrawn
    /// 被限流，并给出建议重试秒数。
    case rateLimited(retryAfterSeconds: Int)
    /// 准入当前不可用，附带不可用原因。
    case unavailable(V2CommandAdmissionUnavailableReason)
}


/// 消息撤回存储错误。
public enum V2MessageWithdrawalStoreError: Error, Equatable, Sendable {
    /// 房间不存在。
    case roomNotFound
    /// 消息不存在。
    case messageNotFound
    /// 发起者不是消息作者。
    case actorNotAuthor
    /// 持久化记录缺失或字段无法解码。
    case corruptPersistenceState
}
