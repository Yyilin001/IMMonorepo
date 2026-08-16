import Foundation

/// Server-authoritative capabilities for a group role.  These are durable
/// policy names, not UI switches; a newly added capability must be assigned a
/// deliberate default before it can be used by a gateway command.
public enum V2GroupPermission: String, CaseIterable, Codable, Hashable, Sendable {
    case sendMessages = "send_messages"
    case inviteMembers = "invite_members"
    case removeMembers = "remove_members"
    case changeMemberRoles = "change_member_roles"
    case pinMessages = "pin_messages"
    case manageAnnouncements = "manage_announcements"
    case moderateMessages = "moderate_messages"
    case muteMembers = "mute_members"
}

public struct V2GroupRolePermissions: Equatable, Sendable {
    public let role: V2RoomMembershipRole
    public let permissions: Set<V2GroupPermission>

    public init(role: V2RoomMembershipRole, permissions: Set<V2GroupPermission>) {
        self.role = role
        self.permissions = permissions
    }
}

/// Ownership is structural and is intentionally not represented by a
/// mutable capability: neither policy editing nor role updates can delegate
/// or remove the final owner.
public enum V2GroupPermissionDefaults {
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

    public static func allows(role: V2RoomMembershipRole, permission: V2GroupPermission, configured: Set<V2GroupPermission>?) -> Bool {
        // Direct rooms do not consult this model. For groups, an absent
        // override selects the explicit built-in role policy.
        guard role != .owner else { return true }
        return (configured ?? permissions(for: role)).contains(permission)
    }
}

public enum V2GroupPermissionValidationError: Error, Equatable, Sendable {
    case ownerPolicyIsImmutable
    case memberRoleCannotBeOwner
    case emptyAnnouncement
    case announcementTooLarge
}
