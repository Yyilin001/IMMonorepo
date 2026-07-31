import Foundation

/// A server-issued revision of one profile fact. Revisions are comparable only
/// when they belong to the same fact scope; callers must not combine them into
/// an arithmetic "resolved version".
public struct V2ProfileRevision: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: UInt64

    public init?(rawValue: UInt64) {
        guard rawValue > 0 else { return nil }
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The immutable media identity of an avatar. A replacement avatar receives a
/// new media ID; signed download URLs remain a transport concern and never
/// become part of a profile projection.
public struct V2AvatarReference: Codable, Hashable, Sendable {
    public let mediaID: MediaID

    public init(mediaID: MediaID) {
        self.mediaID = mediaID
    }
}

public enum V2ProfileState: String, Codable, CaseIterable, Sendable {
    case active
    case deleted
    case suspended
    case hidden
}

/// A viewer-authorized representation of a user's global public profile.
/// `visibilityRevision` changes when the representation available to this
/// viewer changes, even if the target's public-profile revision does not.
public struct V2ProfileView: Codable, Equatable, Sendable {
    public let userID: UserID
    public let publicIdentity: V2PublicIdentity?
    public let avatar: V2AvatarReference?
    public let state: V2ProfileState
    public let revision: V2ProfileRevision
    public let visibilityRevision: V2ProfileRevision

    public init(
        userID: UserID,
        publicIdentity: V2PublicIdentity?,
        avatar: V2AvatarReference?,
        state: V2ProfileState,
        revision: V2ProfileRevision,
        visibilityRevision: V2ProfileRevision
    ) throws {
        switch state {
        case .active:
            guard let publicIdentity, publicIdentity.userID == userID else {
                throw V2ProfilePresentationValidationError.invalidProfileView
            }
        case .deleted, .suspended, .hidden:
            guard publicIdentity == nil, avatar == nil else {
                throw V2ProfilePresentationValidationError.invalidProfileView
            }
        }
        self.userID = userID
        self.publicIdentity = publicIdentity
        self.avatar = avatar
        self.state = state
        self.revision = revision
        self.visibilityRevision = visibilityRevision
    }
}

/// A compact, durable prompt to re-read a profile view. It carries no display
/// data and is safe to replay through a recipient's sync log.
public struct V2ProfileInvalidation: Codable, Equatable, Sendable {
    public let userID: UserID
    public let minimumRevision: V2ProfileRevision

    public init(userID: UserID, minimumRevision: V2ProfileRevision) {
        self.userID = userID
        self.minimumRevision = minimumRevision
    }
}

/// The complete desired mutable profile state. Requiring an expected revision
/// prevents a slow edit form from silently overwriting a newer avatar or
/// display name; the operation ID makes a lost HTTP response safe to retry.
public struct V2ProfileUpdateCommand: Sendable {
    public let actorUserID: UserID
    public let operationID: ProfileUpdateOperationID
    public let expectedRevision: V2ProfileRevision
    public let displayName: String
    public let avatar: V2AvatarReference?

    public init(
        actorUserID: UserID,
        operationID: ProfileUpdateOperationID,
        expectedRevision: V2ProfileRevision,
        displayName: String,
        avatar: V2AvatarReference?
    ) throws {
        // Reuse the established public-name validation and normalization.
        _ = try V2PublicIdentity(userID: actorUserID, handle: .init("profile_update"), displayName: displayName)
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.expectedRevision = expectedRevision
        self.displayName = displayName
        self.avatar = avatar
    }
}

/// The server validates every requested context before returning a profile.
/// This prevents a batch profile API from becoming an internal-ID directory.
public enum V2ProfileViewContext: Hashable, Sendable {
    case directConversation
    /// A current pending or accepted relationship authorizes a bounded
    /// contact-card read. This is deliberately distinct from a direct room:
    /// a contact list must not manufacture a chat room merely to display an
    /// already-authorized public identity.
    case relationship
    case room(RoomID)
}

public struct V2ProfileViewLookupKey: Hashable, Sendable {
    public let userID: UserID
    public let context: V2ProfileViewContext

    public init(userID: UserID, context: V2ProfileViewContext) {
        self.userID = userID
        self.context = context
    }
}

public enum V2ProfileViewLookupLimits {
    public static let maximumKeys = 100
}

public enum V2ProfileViewLookupResult: Equatable, Sendable {
    case profile(key: V2ProfileViewLookupKey, view: V2ProfileView)
    /// Intentionally conflates absent, blocked, and unauthorized values.
    case unavailable(key: V2ProfileViewLookupKey)

    public var key: V2ProfileViewLookupKey {
        switch self {
        case .profile(let key, _), .unavailable(let key): key
        }
    }
}

/// Private data owned by one account. It is never part of another user's
/// public profile or a group roster projection.
public struct V2ContactAlias: Codable, Equatable, Sendable {
    public let ownerUserID: UserID
    public let targetUserID: UserID
    public let remarkName: String?
    public let revision: V2ProfileRevision

    public init(ownerUserID: UserID, targetUserID: UserID, remarkName: String?, revision: V2ProfileRevision) throws {
        let normalized = Self.normalizedName(remarkName)
        guard normalized != nil || remarkName == nil else {
            throw V2ProfilePresentationValidationError.invalidDisplayName
        }
        self.ownerUserID = ownerUserID
        self.targetUserID = targetUserID
        self.remarkName = normalized
        self.revision = revision
    }

    fileprivate static func normalizedName(_ name: String?) -> String? {
        guard let name else { return nil }
        let normalized = name.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count <= 80,
              normalized.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return normalized
    }
}

/// Group-scoped presentation data. It intentionally excludes global display
/// name and avatar to avoid write amplification when a member edits a profile.
public struct V2GroupMemberPresentation: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let userID: UserID
    public let groupNickname: String?
    public let revision: V2ProfileRevision

    public init(roomID: RoomID, userID: UserID, groupNickname: String?, revision: V2ProfileRevision) throws {
        let normalized = V2ContactAlias.normalizedName(groupNickname)
        guard normalized != nil || groupNickname == nil else {
            throw V2ProfilePresentationValidationError.invalidDisplayName
        }
        self.roomID = roomID
        self.userID = userID
        self.groupNickname = normalized
        self.revision = revision
    }
}

public enum V2ProfileDisplaySurface: Sendable {
    case directConversation
    case groupMessage(allowsPrivateAlias: Bool)
    case groupMemberList(allowsPrivateAlias: Bool)
}

/// The full dependency vector for a presentation. It is equatable and
/// hashable for UI invalidation, but deliberately has no ordering relation.
public struct V2ResolvedProfileDependency: Hashable, Sendable {
    public let profileRevision: V2ProfileRevision?
    public let aliasRevision: V2ProfileRevision?
    public let groupMemberRevision: V2ProfileRevision?
    public let visibilityRevision: V2ProfileRevision?

    public init(profileRevision: V2ProfileRevision?, aliasRevision: V2ProfileRevision?, groupMemberRevision: V2ProfileRevision?, visibilityRevision: V2ProfileRevision?) {
        self.profileRevision = profileRevision
        self.aliasRevision = aliasRevision
        self.groupMemberRevision = groupMemberRevision
        self.visibilityRevision = visibilityRevision
    }
}

public struct V2ResolvedProfile: Equatable, Sendable {
    public let userID: UserID
    public let displayName: String
    public let avatar: V2AvatarReference?
    public let state: V2ProfileState
    public let dependency: V2ResolvedProfileDependency

    public init(userID: UserID, displayName: String, avatar: V2AvatarReference?, state: V2ProfileState, dependency: V2ResolvedProfileDependency) {
        self.userID = userID
        self.displayName = displayName
        self.avatar = avatar
        self.state = state
        self.dependency = dependency
    }
}

/// A pure resolver shared by every UI surface. Fetching, persistence, and UI
/// observation live outside this type, keeping resolution deterministic.
public enum V2ProfileResolver {
    public static func resolve(
        userID: UserID,
        profile: V2ProfileView?,
        alias: V2ContactAlias?,
        groupMember: V2GroupMemberPresentation?,
        surface: V2ProfileDisplaySurface
    ) -> V2ResolvedProfile {
        let matchingProfile = profile?.userID == userID ? profile : nil
        let matchingAlias = alias?.targetUserID == userID ? alias : nil
        let matchingGroupMember = groupMember?.userID == userID ? groupMember : nil
        let privateAliasAllowed: Bool
        let groupNameAllowed: Bool
        switch surface {
        case .directConversation:
            privateAliasAllowed = true
            groupNameAllowed = false
        case .groupMessage(let allowsPrivateAlias), .groupMemberList(let allowsPrivateAlias):
            privateAliasAllowed = allowsPrivateAlias
            groupNameAllowed = true
        }

        let state = matchingProfile?.state ?? .hidden
        let publicName = matchingProfile?.publicIdentity?.displayName
        let displayName: String
        if state != .active, matchingProfile != nil {
            displayName = fallbackName(for: state)
        } else if privateAliasAllowed, let remark = matchingAlias?.remarkName {
            displayName = remark
        } else if groupNameAllowed, let groupNickname = matchingGroupMember?.groupNickname {
            displayName = groupNickname
        } else if let publicName {
            displayName = publicName
        } else {
            displayName = fallbackName(for: matchingProfile?.state)
        }

        let avatar = state == .active ? matchingProfile?.avatar : nil
        return .init(
            userID: userID,
            displayName: displayName,
            avatar: avatar,
            state: state,
            dependency: .init(
                profileRevision: matchingProfile?.revision,
                aliasRevision: matchingAlias?.revision,
                groupMemberRevision: matchingGroupMember?.revision,
                visibilityRevision: matchingProfile?.visibilityRevision
            )
        )
    }

    private static func fallbackName(for state: V2ProfileState?) -> String {
        switch state {
        case .deleted: "已注销用户"
        case .suspended: "受限用户"
        case .hidden, .none: "资料暂不可用"
        case .active: "资料暂不可用"
        }
    }
}

public enum V2ProfilePresentationValidationError: Error, Equatable, Sendable {
    case invalidProfileView
    case invalidDisplayName
}
