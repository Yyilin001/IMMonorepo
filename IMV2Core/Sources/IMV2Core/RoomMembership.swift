import Foundation

/// 房间成员的显式角色类别；仅携带角色值不代表已通过授权，成员添加或移除命令不隐式提升角色。
public enum V2RoomMembershipRole: String, Codable, Equatable, Sendable {
    /// 房间所有者。
    case owner
    /// 房间管理员。
    case admin
    /// 普通成员。
    case member
}

/// 成员集合变更动作，不用于修改角色。
public enum V2RoomMembershipAction: String, Codable, Equatable, Sendable {
    /// 添加目标成员。
    case add
    /// 移除目标成员。
    case remove
}

/// 带预期成员修订号的成员变更命令。
///
/// operationID 是持久业务意图，不是传输请求号。响应丢失后重试应保留所有不可变字段，字段变化由服务端判为幂等冲突。
public struct V2ChangeRoomMembershipCommand: Equatable, Sendable {
    /// 目标房间。
    public let roomID: RoomID
    /// 操作者身份，构造器不验证其管理权限。
    public let actorUserID: UserID
    /// 本次变更的稳定幂等操作身份。
    public let operationID: MembershipOperationID
    /// 待添加或移除的用户。
    public let targetUserID: UserID
    /// 成员集合变更动作。
    public let action: V2RoomMembershipAction
    /// 调用者观察到的成员修订号，由权威事务比较。
    public let expectedRevision: V2MembershipRevision
    /// 预期成员修订号的 UInt64 原始值。
    public var expectedMembershipRevision: UInt64 { expectedRevision.rawValue }

    /// 构造成员变更命令，拒绝操作者与目标相同，再校验预期成员版本。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - actorUserID: 请求操作者。
    ///   - operationID: 本次变更稳定身份。
    ///   - targetUserID: 添加或移除对象，必须不同于操作者。
    ///   - action: 成员集合动作。
    ///   - expectedMembershipRevision: 调用者观察到的成员版本。
    /// - Throws: 自身目标报告 selfTargetingNotAllowed；版本范围错误由 V2MembershipRevision 报告。
    ///
    /// 不读取实际成员状态、容量或管理权限。
    public init(
        roomID: RoomID,
        actorUserID: UserID,
        operationID: MembershipOperationID,
        targetUserID: UserID,
        action: V2RoomMembershipAction,
        expectedMembershipRevision: UInt64
    ) throws {
        guard actorUserID != targetUserID else { throw V2RoomMembershipValidationError.selfTargetingNotAllowed }
        self.roomID = roomID
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.targetUserID = targetUserID
        self.action = action
        self.expectedRevision = try .init(expectedMembershipRevision)
    }
}

/// 成员变更后的版本、事件及扇出结果，调用方应从同一权威事务构造。
public struct V2RoomMembershipChange: Equatable, Sendable {
    /// 目标房间。
    public let roomID: RoomID
    /// 待添加或移除的用户。
    public let targetUserID: UserID
    /// 成员集合变更动作。
    public let action: V2RoomMembershipAction
    /// 变更后的正成员修订号。
    public let membershipRevision: UInt64
    /// 成员事件的正房间序号。
    public let roomSequence: UInt64
    /// 对应成员变更事件身份。
    public let eventID: EventID
    /// 对应扇出计划身份。
    public let fanoutPlanID: FanoutPlanID
    /// 变更创建时间，构造器不校验日期。
    public let createdAt: Date

    /// 保存成员变更结果，要求成员版本与房间序号均在 1 到 Int64.max。
    ///
    /// - Throws: 任一数值越界时抛出 outOfRange。
    ///
    /// 不验证相对旧版本的递增关系、目标实际成员状态、日期或提交状态。
    public init(roomID: RoomID, targetUserID: UserID, action: V2RoomMembershipAction, membershipRevision: UInt64, roomSequence: UInt64, eventID: EventID, fanoutPlanID: FanoutPlanID, createdAt: Date) throws {
        guard membershipRevision > 0, membershipRevision <= UInt64(Int64.max),
              roomSequence > 0, roomSequence <= UInt64(Int64.max)
        else { throw V2RevisionValidationError.outOfRange }
        self.roomID = roomID
        self.targetUserID = targetUserID
        self.action = action
        self.membershipRevision = membershipRevision
        self.roomSequence = roomSequence
        self.eventID = eventID
        self.fanoutPlanID = fanoutPlanID
        self.createdAt = createdAt
    }
}

/// 成员变更命令的目标校验错误。
public enum V2RoomMembershipValidationError: Error, Equatable, Sendable {
    /// 操作者与目标相同，此命令不处理自加入或自行退出。
    case selfTargetingNotAllowed
}
