import Foundation

/// 用户短期活动事实的披露偏好，不改变已读事实采集或消息投递。
public struct V2LiveActivityPreferences: Equatable, Sendable {
    /// 是否允许披露在线状态。
    public let allowsOnlinePresence: Bool
    /// 是否允许披露输入活动。
    public let allowsTypingIndicators: Bool
    /// 偏好更新时间。
    public let updatedAt: Date

    /// 构造不可变状态值。
    ///
    /// - Parameters:
    ///   - allowsOnlinePresence: 是否允许披露在线状态。
    ///   - allowsTypingIndicators: 是否允许披露输入活动。
    ///   - updatedAt: 偏好更新时间。
    ///
    /// 保存开关及日期，不执行偏好更新或日期校验。
    public init(allowsOnlinePresence: Bool, allowsTypingIndicators: Bool, updatedAt: Date) {
        self.allowsOnlinePresence = allowsOnlinePresence
        self.allowsTypingIndicators = allowsTypingIndicators
        self.updatedAt = updatedAt
    }
}

/// 修改账户短期活动披露偏好的稳定业务意图。
public struct V2SetLiveActivityPreferencesCommand: Equatable, Sendable {
    /// 偏好所属认证用户。
    public let actorUserID: UserID
    /// 本次修改的稳定操作身份。
    public let operationID: LiveActivityPreferenceOperationID
    /// 期望的在线披露开关。
    public let allowsOnlinePresence: Bool
    /// 期望的输入活动披露开关。
    public let allowsTypingIndicators: Bool

    /// 构造不可变状态值。
    ///
    /// - Parameters:
    ///   - actorUserID: 偏好所属认证用户。
    ///   - operationID: 本次修改的稳定操作身份。
    ///   - allowsOnlinePresence: 期望的在线披露开关。
    ///   - allowsTypingIndicators: 期望的输入活动披露开关。
    ///
    /// 保存命令字段，不检查用户权限或操作是否已执行。
    public init(actorUserID: UserID, operationID: LiveActivityPreferenceOperationID, allowsOnlinePresence: Bool, allowsTypingIndicators: Bool) {
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.allowsOnlinePresence = allowsOnlinePresence
        self.allowsTypingIndicators = allowsTypingIndicators
    }
}

/// 仅用于展示的短期在线事实，受服务端租约期限约束。
///
/// 期限到达后应展示离线，不等待后续连接事件；此快照不会自行调度到期更新。
public struct V2PresenceState: Equatable, Sendable {
    /// 在线查询上下文房间。
    public let roomID: RoomID
    /// 被展示状态的用户。
    public let targetUserID: UserID
    /// 该快照声明的在线状态。
    public let isOnline: Bool
    /// 展示有效期，不能在到期后继续沿用在线值。
    public let expiresAt: Date

    /// 构造不可变状态值。
    ///
    /// - Parameters:
    ///   - roomID: 在线查询上下文房间。
    ///   - targetUserID: 被展示状态的用户。
    ///   - isOnline: 该快照声明的在线状态。
    ///   - expiresAt: 展示有效期，不能在到期后继续沿用在线值。
    ///
    /// 直接保存字段，不验证日期有限性、是否已到期或房间可见性。
    public init(roomID: RoomID, targetUserID: UserID, isOnline: Bool, expiresAt: Date) {
        self.roomID = roomID
        self.targetUserID = targetUserID
        self.isOnline = isOnline
        self.expiresAt = expiresAt
    }
}

/// 房间内用户的短期输入活动快照，不包含输入正文或持久消息内容。
public struct V2TypingState: Equatable, Sendable {
    /// 输入活动所属房间。
    public let roomID: RoomID
    /// 正在输入或停止输入的用户。
    public let userID: UserID
    /// 当前快照是否表示输入中。
    public let isTyping: Bool
    /// 短期输入状态的期限，展示者负责到期失效。
    public let expiresAt: Date

    /// 构造不可变状态值。
    ///
    /// - Parameters:
    ///   - roomID: 输入活动所属房间。
    ///   - userID: 正在输入或停止输入的用户。
    ///   - isTyping: 当前快照是否表示输入中。
    ///   - expiresAt: 短期输入状态的期限，展示者负责到期失效。
    ///
    /// 直接保存输入活动字段，不执行计时器、权限或时间校验。
    public init(roomID: RoomID, userID: UserID, isTyping: Bool, expiresAt: Date) {
        self.roomID = roomID
        self.userID = userID
        self.isTyping = isTyping
        self.expiresAt = expiresAt
    }
}
