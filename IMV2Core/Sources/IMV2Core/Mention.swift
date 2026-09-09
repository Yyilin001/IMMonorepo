import Foundation

/// 消息意图中不可变的提及目标，不包含显示名、文本偏移或客户端声称的成员权限。
public enum V2MentionTarget: Hashable, Sendable {
    /// 提及一个明确用户。
    case user(UserID)
    /// 广播提及，由发送者角色决定是否允许。
    case everyone
}

/// 单条消息提及目标数量配置。
public struct V2MentionLimits: Equatable, Sendable {
    /// 目标数量上限，默认 20，必须为正。
    public let maximumTargets: Int

    /// 要求目标上限大于零，否则抛出 invalidLimits；不设置额外最大上限。
    public init(maximumTargets: Int = 20) throws {
        guard maximumTargets > 0 else { throw V2MentionValidationError.invalidLimits }
        self.maximumTargets = maximumTargets
    }
}

/// 消息接受时由服务端提供的冻结可见性视图，不能从设备本地成员缓存拼装为授权依据。
public struct V2MentionVisibility: Sendable {
    /// 发送者在当前授权视图中的角色。
    public let senderRole: V2RoomMembershipRole
    /// 当前可见且有效的用户集合。
    public let visibleActiveUsers: Set<UserID>
    /// 其他业务策略允许提及的用户集合，授权要求同时属于两个集合。
    public let mentionableUsers: Set<UserID>

    /// 保存服务端计算的角色与集合，不验证集合来源、成员版本或二者包含关系。
    public init(senderRole: V2RoomMembershipRole, visibleActiveUsers: Set<UserID>, mentionableUsers: Set<UserID>) {
        self.senderRole = senderRole
        self.visibleActiveUsers = visibleActiveUsers
        self.mentionableUsers = mentionableUsers
    }
}

/// 根据冻结可见性视图校验提及目标，不加载成员、不解析文本或执行持久化。
public enum V2MentionAuthorization {
    /// 检查提及数量、去重与授权条件，不改变输入顺序或集合。
    ///
    /// - Parameters:
    ///   - targets: 消息提及目标，允许空数组，但不能重复。
    ///   - visibility: 服务端生成的一致可见性视图。
    ///   - limits: 目标数量上限。
    /// - Throws: 超限或重复报告 invalidTargetSet；具体目标不可提及或广播权限不足统一报告 notAuthorized。
    ///
    /// 广播要求 owner 或 admin；单用户必须同时属于 visibleActiveUsers 和 mentionableUsers。
    /// 不披露目标离开、不可见或被阻止等具体原因；不检查提及文本范围，也不额外禁止广播与单用户并存。
    public static func authorize(_ targets: [V2MentionTarget], visibility: V2MentionVisibility, limits: V2MentionLimits) throws {
        guard targets.count <= limits.maximumTargets,
              Set(targets).count == targets.count
        else { throw V2MentionValidationError.invalidTargetSet }
        for target in targets {
            switch target {
            case .everyone:
                guard visibility.senderRole == .owner || visibility.senderRole == .admin else {
                    throw V2MentionValidationError.notAuthorized
                }
            case .user(let userID):
                guard visibility.visibleActiveUsers.contains(userID),
                      visibility.mentionableUsers.contains(userID)
                else { throw V2MentionValidationError.notAuthorized }
            }
        }
    }
}

/// 提及配置、目标集合与授权错误。
public enum V2MentionValidationError: Error, Equatable, Sendable {
    /// 数量上限非正。
    case invalidLimits
    /// 目标超限或包含重复值。
    case invalidTargetSet
    /// 至少一个目标不满足授权条件，不携带目标特定原因。
    case notAuthorized
}
