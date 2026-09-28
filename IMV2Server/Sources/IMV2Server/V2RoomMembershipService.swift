import Foundation
import IMV2Core

/// 通过认证的成员变更请求。
public struct V2AuthenticatedMembershipChange: Sendable {
    /// 目标房间。
    public let roomID: RoomID
    /// 发起变更的用户。
    public let actorUserID: UserID
    /// 本次变更的幂等操作标识。
    public let operationID: MembershipOperationID
    /// 变更目标用户。
    public let targetUserID: UserID
    /// 需要执行的动作。
    public let action: V2RoomMembershipAction
    /// 客户端观察到的成员修订，用于并发冲突检测。
    public let expectedMembershipRevision: UInt64

    /// 保存已认证的成员变更请求。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - actorUserID: 发起变更的用户。
    ///   - operationID: 幂等操作标识。
    ///   - targetUserID: 变更目标用户。
    ///   - action: 需要执行的动作。
    ///   - expectedMembershipRevision: 期望的成员修订。
    public init(roomID: RoomID, actorUserID: UserID, operationID: MembershipOperationID, targetUserID: UserID, action: V2RoomMembershipAction, expectedMembershipRevision: UInt64) {
        self.roomID = roomID
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.targetUserID = targetUserID
        self.action = action
        self.expectedMembershipRevision = expectedMembershipRevision
    }
}

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
