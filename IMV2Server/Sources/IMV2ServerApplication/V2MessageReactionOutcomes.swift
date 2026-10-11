import IMV2ServerContracts
import Foundation
import IMV2Core

/// 消息表态的处理结果。
public enum V2MessageReactionOutcome: Equatable, Sendable {
    /// 本次调用实际改变了表态状态。
    case changed(V2MessageReactionChange)
    /// 该操作此前已成功提交，本次为重放，返回相同变更。
    case idempotent(V2MessageReactionChange)
    /// 同一操作标识提交了与首次不同的载荷。
    case idempotencyConflict
    /// 目标状态与请求一致，无需改动。
    case alreadyInDesiredState
    /// 触发限流；关联值为建议的重试等待秒数。
    case rateLimited(retryAfterSeconds: Int)
    /// 房间写入准入暂时不可用。
    case unavailable(V2CommandAdmissionUnavailableReason)
}


/// 消息表态存储的错误分类。
public enum V2MessageReactionStoreError: Error, Equatable, Sendable {
    /// 目标房间不存在。
    case roomNotFound
    /// 目标消息不存在。
    case messageNotFound
    /// 发起者不是房间成员。
    case actorNotMember
    /// 目标消息已撤回。
    case messageWithdrawn
    /// 该消息的表态数量已达上限。
    case reactionLimitReached
    /// 持久化状态与预期不一致。
    case corruptPersistenceState
}
