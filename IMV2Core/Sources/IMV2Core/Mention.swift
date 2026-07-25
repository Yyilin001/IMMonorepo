import Foundation

/// A mention is an immutable part of a message intent. It never contains a
/// display name or a client-supplied membership claim.
public enum V2MentionTarget: Hashable, Sendable {
    case user(UserID)
    case everyone
}

public struct V2MentionLimits: Equatable, Sendable {
    public let maximumTargets: Int

    public init(maximumTargets: Int = 20) throws {
        guard maximumTargets > 0 else { throw V2MentionValidationError.invalidLimits }
        self.maximumTargets = maximumTargets
    }
}

/// A frozen, server-derived visibility view used at message acceptance. The
/// caller must never populate this from a device member cache.
public struct V2MentionVisibility: Sendable {
    public let senderRole: V2RoomMembershipRole
    public let visibleActiveUsers: Set<UserID>
    public let mentionableUsers: Set<UserID>

    public init(senderRole: V2RoomMembershipRole, visibleActiveUsers: Set<UserID>, mentionableUsers: Set<UserID>) {
        self.senderRole = senderRole
        self.visibleActiveUsers = visibleActiveUsers
        self.mentionableUsers = mentionableUsers
    }
}

public enum V2MentionAuthorization {
    /// A rejected result intentionally has no target-specific reason: callers
    /// must not learn whether a user left, is invisible, or is blocked.
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

public enum V2MentionValidationError: Error, Equatable, Sendable {
    case invalidLimits
    case invalidTargetSet
    case notAuthorized
}
