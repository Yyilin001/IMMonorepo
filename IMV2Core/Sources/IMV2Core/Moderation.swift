import Foundation

/// 与普通撤回和成员变更分离的管理动作，稳定操作身份与审计元数据共同参与重试比较。
public enum V2ModerationAction: String, Codable, CaseIterable, Equatable, Sendable {
    /// 管理性移除消息内容，不等同于发送者普通撤回。
    case redactMessage
    /// 管理性移除目标成员。
    case removeMember
    /// 设置目标成员临时禁言。
    case muteMember
    /// 冻结房间，仅供独立可信管理路径使用。
    case freezeRoom
    /// 解除房间冻结，仅供独立可信管理路径使用。
    case unfreezeRoom
}

/// 结构化管理原因代码，避免把报告正文、消息内容、令牌或显示名放入房间事件与运行日志。
///
/// 普通构造器限制字符集；合成 Codable 解码不调用该构造器，外部边界仍需保证校验。
public struct V2ModerationReasonCode: Hashable, Codable, Sendable {
    /// 裁剪后的原因代码，保留大小写。
    public let rawValue: String

    /// 移除首尾空白与换行后，要求非空、最多 64 个 UTF-8 字节且仅含 ASCII 字母、数字、下划线或连字符；否则抛出 invalidReasonCode。
    public init(_ rawValue: String) throws {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.utf8.count <= 64,
              normalized.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
        else { throw V2ModerationValidationError.invalidReasonCode }
        self.rawValue = normalized
    }
}

/// 显式表示各动作相关字段的不可变管理命令，供持久化幂等记录精确比较重试内容。
///
/// 构造器只检查字段组合，身份授权、时间有效性及目标当前状态由业务层继续校验。
public struct V2ModerationCommand: Equatable, Sendable {
    /// 操作所属房间。
    public let roomID: RoomID
    /// 请求操作者，不表示已通过角色或可信服务认证。
    public let actorUserID: UserID
    /// 本次管理动作的稳定幂等身份。
    public let operationID: ModerationOperationID
    /// 管理动作类型，决定哪些可选字段必须存在。
    public let action: V2ModerationAction
    /// 移除或禁言目标，必须不同于操作者；其余动作不允许该字段。
    public let targetUserID: UserID?
    /// 内容管理目标，仅 redactMessage 使用。
    public let messageID: MessageID?
    /// 可选内容版本，仅 redactMessage 接受；可信自动处理可据此绑定判断，普通管理路径应不填。
    public let expectedMessageRevision: UInt64?
    /// 禁言排他截止时间，仅 muteMember 要求存在；构造器不检查有限性或是否未来。
    public let muteUntil: Date?
    /// 结构化审计原因代码。
    public let reasonCode: V2ModerationReasonCode

    /// 按动作校验命令字段组合并保存完整意图。
    ///
    /// - Parameters:
    ///   - roomID: 所属房间。
    ///   - actorUserID: 操作者。
    ///   - operationID: 稳定操作身份。
    ///   - action: 管理动作。
    ///   - targetUserID: 仅移除或禁言使用，不能为操作者本人。
    ///   - messageID: 仅内容管理使用，必须提供。
    ///   - expectedMessageRevision: 内容管理可选版本，提供时需在 1 到 Int64.max。
    ///   - muteUntil: 仅禁言使用，必须提供，时间合法性后续检查。
    ///   - reasonCode: 审计原因代码。
    /// - Throws: 字段缺失、动作不允许的字段存在，或可选版本越界时抛出 invalidActionShape。
    ///
    /// 冻结与解冻不得携带目标、消息、版本或禁言期限；不执行数据库写入。
    public init(roomID: RoomID, actorUserID: UserID, operationID: ModerationOperationID, action: V2ModerationAction, targetUserID: UserID? = nil, messageID: MessageID? = nil, expectedMessageRevision: UInt64? = nil, muteUntil: Date? = nil, reasonCode: V2ModerationReasonCode) throws {
        switch action {
        case .redactMessage:
            guard targetUserID == nil, messageID != nil, muteUntil == nil,
                  expectedMessageRevision.map({ $0 > 0 && $0 <= UInt64(Int64.max) }) ?? true
            else { throw V2ModerationValidationError.invalidActionShape }
        case .removeMember:
            guard let targetUserID, targetUserID != actorUserID, messageID == nil, expectedMessageRevision == nil, muteUntil == nil else { throw V2ModerationValidationError.invalidActionShape }
        case .muteMember:
            guard let targetUserID, targetUserID != actorUserID, messageID == nil, expectedMessageRevision == nil, muteUntil != nil else { throw V2ModerationValidationError.invalidActionShape }
        case .freezeRoom, .unfreezeRoom:
            guard targetUserID == nil, messageID == nil, expectedMessageRevision == nil, muteUntil == nil else { throw V2ModerationValidationError.invalidActionShape }
        }
        self.roomID = roomID
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.action = action
        self.targetUserID = targetUserID
        self.messageID = messageID
        self.expectedMessageRevision = expectedMessageRevision
        self.muteUntil = muteUntil
        self.reasonCode = reasonCode
    }
}

/// 普通账户连接的管理权限判断，与独立可信服务及审核后台认证路径分离。
///
/// 冻结和解冻在此始终拒绝。其他动作使用角色的有效权限集合，因此显式策略可向普通成员授予相应能力，不能只凭枚举名称假设限于管理员。
public enum V2ModerationAuthorization {
    /// 检查管理能力，并在禁言动作中验证有限且严格晚于当前时间的期限。
    ///
    /// - Parameters:
    ///   - actorRole: 权威成员角色。
    ///   - configuredPermissions: 可选覆盖集合，nil 使用默认值，空集合不授予非群主能力。
    ///   - action: 要检查的动作，调用方必须保证与 command.action 一致。
    ///   - now: 当前时钟；禁言时要求有限。
    ///   - command: 提供禁言截止时间的完整命令。
    /// - Throws: 冻结、解冻或缺少对应能力时抛出 notAuthorized；禁言期限缺失、非有限或不晚于 now 时抛出 invalidMuteExpiry。
    ///
    /// 内容管理、移除和禁言分别要求 moderateMessages、removeMembers 和 muteMembers。此方法不检查 action 与 command.action 相同、不判断目标角色层级，也不执行持久化。
    public static func authorize(actorRole: V2RoomMembershipRole, configuredPermissions: Set<V2GroupPermission>? = nil, action: V2ModerationAction, now: Date, command: V2ModerationCommand) throws {
        // A member-authenticated gateway connection never represents the
        // separately authenticated safety-service authority. Freeze/unfreeze
        // therefore cannot accidentally be granted to an owner or admin by
        // reusing this policy boundary.
        guard action != .freezeRoom, action != .unfreezeRoom else {
            throw V2ModerationAuthorizationError.notAuthorized
        }
        let required: V2GroupPermission = switch action {
        case .redactMessage: .moderateMessages
        case .removeMember: .removeMembers
        case .muteMember: .muteMembers
        case .freezeRoom, .unfreezeRoom: preconditionFailure("trusted actions are rejected above")
        }
        guard V2GroupPermissionDefaults.allows(role: actorRole, permission: required, configured: configuredPermissions) else {
            throw V2ModerationAuthorizationError.notAuthorized
        }
        if action == .muteMember {
            guard let muteUntil = command.muteUntil,
                  now.timeIntervalSince1970.isFinite,
                  muteUntil.timeIntervalSince1970.isFinite,
                  muteUntil > now else { throw V2ModerationValidationError.invalidMuteExpiry }
        }
    }
}

/// 管理命令的原因代码、字段组合或期限错误。
public enum V2ModerationValidationError: Error, Equatable, Sendable {
    /// 原因代码为空、超长或字符集非法。
    case invalidReasonCode
    /// 字段组合不符合动作要求，或可选内容版本越界。
    case invalidActionShape
    /// 禁言期限缺失、时钟或期限非有限，或期限不严格晚于当前时间。
    case invalidMuteExpiry
}

/// 普通账户管理权限检查失败。
public enum V2ModerationAuthorizationError: Error, Equatable, Sendable {
    /// 该入口不接受动作，或当前有效权限未包含所需能力。
    case notAuthorized
}
