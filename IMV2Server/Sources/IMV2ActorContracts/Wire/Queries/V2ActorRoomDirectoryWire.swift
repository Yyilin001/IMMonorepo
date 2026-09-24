import Foundation
import IMV2Core

public enum V2ActorRoomDirectoryWireError: Error, Equatable, Sendable {
    case invalidRequest
    case invalidCursor
    case invalidPage
    case invalidIdentity
}

/// Explicit mirror avoids treating synthesized V2PublicHandle decoding as validation.
public struct V2ActorPublicIdentityWire: Codable, Equatable, Sendable {
    public let userID: UserID
    public let handle: String
    public let displayName: String
    public let accountKind: V2AccountKind

    public init(userID: UserID, handle: String, displayName: String, accountKind: V2AccountKind) {
        self.userID = userID; self.handle = handle
        self.displayName = displayName; self.accountKind = accountKind
    }
}

public struct V2ActorMembershipDirectoryQueryWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let cursor: String?
    public let pageSize: Int

    public init(roomID: RoomID, actorUserID: UserID, cursor: String?, pageSize: Int) throws {
        let trimmed = cursor?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...100).contains(pageSize),
              trimmed.map({ !$0.isEmpty && $0.utf8.count <= 512 }) ?? true,
              trimmed == cursor else { throw V2ActorRoomDirectoryWireError.invalidRequest }
        self.roomID = roomID; self.actorUserID = actorUserID
        self.cursor = cursor; self.pageSize = pageSize
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(roomID: values.decode(RoomID.self, forKey: .roomID),
                      actorUserID: values.decode(UserID.self, forKey: .actorUserID),
                      cursor: values.decodeIfPresent(String.self, forKey: .cursor),
                      pageSize: values.decode(Int.self, forKey: .pageSize))
    }

    private enum CodingKeys: String, CodingKey { case roomID, actorUserID, cursor, pageSize }
}

public struct V2ActorMembershipDirectoryEntryWire: Codable, Equatable, Sendable {
    public let userID: UserID
    public let role: V2RoomMembershipRole
    public let publicIdentity: V2ActorPublicIdentityWire
    public init(userID: UserID, role: V2RoomMembershipRole,
                publicIdentity: V2ActorPublicIdentityWire) {
        self.userID = userID; self.role = role; self.publicIdentity = publicIdentity
    }
}

public struct V2ActorMembershipDirectoryPageWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let membershipRevision: UInt64
    public let actorRole: V2RoomMembershipRole
    public let entries: [V2ActorMembershipDirectoryEntryWire]
    public let nextCursor: String?

    public init(roomID: RoomID, membershipRevision: UInt64, actorRole: V2RoomMembershipRole,
                entries: [V2ActorMembershipDirectoryEntryWire], nextCursor: String?) {
        self.roomID = roomID; self.membershipRevision = membershipRevision
        self.actorRole = actorRole; self.entries = entries; self.nextCursor = nextCursor
    }
}

public struct V2ActorRoleBaselineQueryWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public init(roomID: RoomID, actorUserID: UserID) {
        self.roomID = roomID; self.actorUserID = actorUserID
    }
}

public struct V2ActorRoleBaselineWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let permissionRevision: UInt64
    public let membershipRevision: UInt64
    public let roomSequence: UInt64
    public let adminPermissions: [V2GroupPermission]
    public let memberPermissions: [V2GroupPermission]

    public init(roomID: RoomID, permissionRevision: UInt64, membershipRevision: UInt64,
                roomSequence: UInt64, adminPermissions: [V2GroupPermission],
                memberPermissions: [V2GroupPermission]) {
        self.roomID = roomID; self.permissionRevision = permissionRevision
        self.membershipRevision = membershipRevision; self.roomSequence = roomSequence
        self.adminPermissions = adminPermissions; self.memberPermissions = memberPermissions
    }
}

public enum V2RoomDirectoryQuery: Codable, Equatable, Sendable {
    case membership(V2ActorMembershipDirectoryQueryWire)
    case roleBaseline(V2ActorRoleBaselineQueryWire)

    public var roomID: RoomID {
        switch self {
        case .membership(let value): value.roomID
        case .roleBaseline(let value): value.roomID
        }
    }
    public var actorUserID: UserID {
        switch self {
        case .membership(let value): value.actorUserID
        case .roleBaseline(let value): value.actorUserID
        }
    }
    public var replayPolicy: V2RoomReplayPolicy { .readOnly }
}

public enum V2ActorMembershipDirectoryErrorWire: Codable, Equatable, Sendable {
    case invalidRequest
    case roomNotFound
    case actorNotMember
    case invalidCursor
    case revisionConflict(currentRevision: UInt64)
    case ownerChanged
    case corruptPersistenceState
}

public enum V2ActorRoleBaselineErrorWire: String, Codable, Equatable, Sendable {
    case roomNotFound, actorNotMember, corruptPersistenceState
}

public enum V2RoomDirectoryResult: Codable, Equatable, Sendable {
    case membershipFailure(V2ActorMembershipDirectoryErrorWire)
    case roleBaselineFailure(V2ActorRoleBaselineErrorWire)
    case membership(V2ActorMembershipDirectoryPageWire)
    case roleBaseline(V2ActorRoleBaselineWire)
}

public enum V2ActorRoomKindWire: String, Codable, Equatable, Sendable {
    case group
    case direct
}

public struct V2ActorUserRoomDirectoryEntryWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let roomKind: V2ActorRoomKindWire
    public let viewerMembershipRevision: UInt64
    public let ownerEpoch: UInt64
    public init(roomID: RoomID, roomKind: V2ActorRoomKindWire,
                viewerMembershipRevision: UInt64, ownerEpoch: UInt64) {
        self.roomID = roomID; self.roomKind = roomKind
        self.viewerMembershipRevision = viewerMembershipRevision; self.ownerEpoch = ownerEpoch
    }
}

/// User/control coordinator query; it is deliberately outside V2RoomDirectoryQuery.
public struct V2ActorUserRoomDirectoryQueryWire: Codable, Equatable, Sendable {
    public let actorUserID: UserID
    public let cursor: String?
    public let pageSize: Int
    public init(actorUserID: UserID, cursor: String?, pageSize: Int) throws {
        guard (1...100).contains(pageSize) else { throw V2ActorRoomDirectoryWireError.invalidRequest }
        guard cursor.map({ !$0.isEmpty && $0.utf8.count <= 2048 }) ?? true else {
            throw V2ActorRoomDirectoryWireError.invalidCursor
        }
        self.actorUserID = actorUserID; self.cursor = cursor; self.pageSize = pageSize
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(actorUserID: values.decode(UserID.self, forKey: .actorUserID),
                      cursor: values.decodeIfPresent(String.self, forKey: .cursor),
                      pageSize: values.decode(Int.self, forKey: .pageSize))
    }
    private enum CodingKeys: String, CodingKey { case actorUserID, cursor, pageSize }
    public var replayPolicy: V2RoomReplayPolicy { .readOnly }
}

public struct V2ActorUserRoomDirectoryPageWire: Codable, Equatable, Sendable {
    public let rooms: [V2ActorUserRoomDirectoryEntryWire]
    public let nextCursor: String?
    public let topologyGeneration: String
    public init(rooms: [V2ActorUserRoomDirectoryEntryWire], nextCursor: String?,
                topologyGeneration: String) {
        self.rooms = rooms; self.nextCursor = nextCursor
        self.topologyGeneration = topologyGeneration
    }
}

/// Physical-store scan progress is distinct from visible entries.
public struct V2ActorUserRoomDirectorySliceWire: Codable, Equatable, Sendable {
    public let entries: [V2ActorUserRoomDirectoryEntryWire]
    public let scannedThrough: RoomID?
    public let hasMore: Bool
    public init(entries: [V2ActorUserRoomDirectoryEntryWire], scannedThrough: RoomID?, hasMore: Bool) {
        self.entries = entries; self.scannedThrough = scannedThrough; self.hasMore = hasMore
    }
}

/// User/control enumeration errors stay with the coordinator operation.
public enum V2ActorUserRoomDirectoryResultWire: Codable, Equatable, Sendable {
    case page(V2ActorUserRoomDirectoryPageWire)
    case failure(V2ActorRoomRecoveryReadErrorWire)
}
