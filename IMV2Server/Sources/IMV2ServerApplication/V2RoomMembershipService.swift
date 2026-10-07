import IMV2ServerContracts
import Foundation
import IMV2Core

/// 成员变更的执行结果。
public enum V2RoomMembershipChangeOutcome: Equatable, Sendable {
    /// 本次调用实际提交了变更。
    case changed(V2RoomMembershipChange)
    /// 同一操作标识已提交过等价变更，返回其原有结果。
    case idempotent(V2RoomMembershipChange)
    /// 同一操作标识已被不同载荷的命令占用。
    case idempotencyConflict
    /// 成员修订与期望值不符，参数为当前修订。
    case revisionConflict(current: UInt64)
    /// 目标用户已经是成员。
    case targetAlreadyMember
    /// 目标用户不是成员。
    case targetNotMember
    /// 成员数量已达到房间上限。
    case memberLimitReached
    /// 被限流，并给出建议重试秒数。
    case rateLimited(retryAfterSeconds: Int)
    /// 准入当前不可用，附带不可用原因。
    case unavailable(V2CommandAdmissionUnavailableReason)
}

/// 成员变更存储错误。
public enum V2RoomMembershipStoreError: Error, Equatable, Sendable {
    /// 房间归属已变更。
    case ownerChanged
    /// 房间不存在。
    case roomNotFound
    /// 发起者不是房间归属所有者。
    case actorNotOwner
    /// 目标用户当前不可用。
    case targetUnavailable
    /// 持久化记录缺失或字段无法解码。
    case corruptPersistenceState
}
