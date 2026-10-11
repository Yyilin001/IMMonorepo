import Foundation

/// 接收者拥有的陌生消息隐私策略，用于既非好友也未形成双方回复私聊关系的用户发来的新消息。
public enum V2StrangerMessagePermission: String, Codable, Equatable, Sendable {
    /// 允许该类新请求，实际准入仍由服务端其他策略共同决定。
    case allow
    /// 拒绝该类新请求，不表示删除既有业务记录。
    case deny
}

/// 接收者拥有的新关系请求策略，不追溯改变已有关系或待处理请求。
public enum V2UserAddPermission: String, Codable, Equatable, Sendable {
    /// 允许该类新请求，实际准入仍由服务端其他策略共同决定。
    case allow
    /// 拒绝该类新请求，不表示删除既有业务记录。
    case deny
}

/// 打开或返回两个不同用户之间唯一私聊房间的业务意图。
///
/// 操作身份跨重连保留，房间唯一性由服务端存储保证；此模型不排序用户、不派生房间身份，也不代表消息发送已获准。
public struct V2OpenDirectRoomCommand: Equatable, Sendable {
    /// 发起打开私聊的用户。
    public let actorUserID: UserID
    /// 本次打开操作的稳定幂等身份。
    public let operationID: DirectRoomOperationID
    /// 私聊目标，必须不同于发起者。
    public let targetUserID: UserID

    /// 构造命令。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起打开私聊的用户。
    ///   - operationID: 本次打开操作的稳定幂等身份。
    ///   - targetUserID: 私聊目标，必须不同于发起者。
    ///
    /// 拒绝操作者与目标相同，抛出 selfTargetingNotAllowed；不检查好友关系、阻止状态或目标是否存在。
    public init(actorUserID: UserID, operationID: DirectRoomOperationID, targetUserID: UserID) throws {
        guard actorUserID != targetUserID else { throw V2DirectMessagingValidationError.selfTargetingNotAllowed }
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.targetUserID = targetUserID
    }
}

/// 修改当前用户的账户级关系请求隐私策略，不改变现有关系或请求。
public struct V2SetUserAddPermissionCommand: Equatable, Sendable {
    /// 策略所属认证用户。
    public let actorUserID: UserID
    /// 稳定关系请求偏好操作身份。
    public let operationID: UserAddPreferenceOperationID
    /// 期望的新关系请求策略。
    public let permission: V2UserAddPermission

    /// 构造命令。
    ///
    /// - Parameters:
    ///   - actorUserID: 策略所属认证用户。
    ///   - operationID: 稳定关系请求偏好操作身份。
    ///   - permission: 期望的新关系请求策略。
    ///
    /// 保存命令字段，不读取或更改既有请求。
    public init(actorUserID: UserID, operationID: UserAddPreferenceOperationID, permission: V2UserAddPermission) {
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.permission = permission
    }
}

/// 私聊打开结果，以本次发起者与目标的方向返回双方身份。
public struct V2DirectRoom: Equatable, Sendable {
    /// 服务端确定的唯一私聊房间。
    public let roomID: RoomID
    /// 本次调用的发起者。
    public let actorUserID: UserID
    /// 本次调用的对方用户。
    public let targetUserID: UserID
    /// 房间创建时间，不应以重试时间替代。
    public let createdAt: Date

    /// 构造私聊结果。
    ///
    /// - Parameters:
    ///   - roomID: 服务端确定的唯一私聊房间。
    ///   - actorUserID: 本次调用的发起者。
    ///   - targetUserID: 本次调用的对方用户。
    ///   - createdAt: 房间创建时间，不应以重试时间替代。
    ///
    /// 直接保存字段，不排序参与者，也不校验双方不同、日期范围或房间归属。
    public init(roomID: RoomID, actorUserID: UserID, targetUserID: UserID, createdAt: Date) {
        self.roomID = roomID
        self.actorUserID = actorUserID
        self.targetUserID = targetUserID
        self.createdAt = createdAt
    }
}

/// 私聊业务输入校验错误。
public enum V2DirectMessagingValidationError: Error, Equatable, Sendable {
    /// 操作者与目标相同，不能通过私聊打开命令与自己建立房间。
    case selfTargetingNotAllowed
}
