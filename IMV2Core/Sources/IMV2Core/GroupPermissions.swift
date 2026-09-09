import Foundation

/// 服务端权威群角色策略中的持久能力名称，不是界面开关。
///
/// 新增能力需明确各角色默认值并在服务端命令路径执行权限检查。
public enum V2GroupPermission: String, CaseIterable, Codable, Hashable, Sendable {
    /// 发送群消息。
    case sendMessages = "send_messages"
    /// 邀请成员。
    case inviteMembers = "invite_members"
    /// 移除成员。
    case removeMembers = "remove_members"
    /// 变更成员角色，不等于转让所有权。
    case changeMemberRoles = "change_member_roles"
    /// 管理置顶消息。
    case pinMessages = "pin_messages"
    /// 管理群公告。
    case manageAnnouncements = "manage_announcements"
    /// 执行消息管理操作。
    case moderateMessages = "moderate_messages"
    /// 管理成员禁言。
    case muteMembers = "mute_members"
}

/// 某个角色及其明确权限集合，不自行应用默认值或判断调用者权限。
public struct V2GroupRolePermissions: Equatable, Sendable {
    /// 该权限集合对应的角色。
    public let role: V2RoomMembershipRole
    /// 显式权限集合，空集合不等于未配置。
    public let permissions: Set<V2GroupPermission>

    /// 保存角色与集合，不限制 owner 输入或验证策略可修改性；命令边界负责这些约束。
    public init(role: V2RoomMembershipRole, permissions: Set<V2GroupPermission>) {
        self.role = role
        self.permissions = permissions
    }
}

/// 群角色的内置默认策略与有效权限判断。
///
/// 群主所有权是结构性约束，不通过可修改权限集合授予或移除；私聊不使用此模型。
public enum V2GroupPermissionDefaults {
    /// 返回角色默认集合：群主拥有全部已知权限，管理员默认拥有除变更成员角色外的其他权限，普通成员默认仅能发送消息。
    public static func permissions(for role: V2RoomMembershipRole) -> Set<V2GroupPermission> {
        switch role {
        case .owner:
            Set(V2GroupPermission.allCases)
        case .admin:
            [.sendMessages, .inviteMembers, .removeMembers, .pinMessages,
             .manageAnnouncements, .moderateMessages, .muteMembers]
        case .member:
            [.sendMessages]
        }
    }

    /// 计算指定群角色是否允许某项能力。
    ///
    /// - Parameters:
    ///   - role: 当前权威角色。
    ///   - permission: 待检查能力。
    ///   - configured: 可选覆盖策略，nil 使用默认值，空集合表示不授予任何能力。
    /// - Returns: 群主始终为 true；其他角色按覆盖或默认集合判断。
    ///
    /// 不读取成员资格或策略版本，输入必须由调用方从一致的权威状态取得。
    public static func allows(role: V2RoomMembershipRole, permission: V2GroupPermission, configured: Set<V2GroupPermission>?) -> Bool {
        // Direct rooms do not consult this model. For groups, an absent
        // override selects the explicit built-in role policy.
        guard role != .owner else { return true }
        return (configured ?? permissions(for: role)).contains(permission)
    }
}

/// 群权限、角色及公告命令的业务校验错误。
public enum V2GroupPermissionValidationError: Error, Equatable, Sendable {
    /// 群主权限策略不能通过普通角色策略修改命令变更。
    case ownerPolicyIsImmutable
    /// 普通成员角色命令不能设置群主身份。
    case memberRoleCannotBeOwner
    /// 公告裁剪后为空白。
    case emptyAnnouncement
    /// 公告 UTF-8 字节数超过命令允许上限。
    case announcementTooLarge
}
