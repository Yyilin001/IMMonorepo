import Foundation
import IMV2Core

/// A bounded, authoritative roster page.  It is deliberately a read API,
/// rather than a sync projection: copying a large room roster into every
/// member's incremental history would turn one membership fact into O(n²)
/// bytes of durable work.
public struct V2RoomMembershipDirectoryEntry: Equatable, Sendable {
    public let userID: UserID
    public let role: V2RoomMembershipRole
    /// Current public chat identity authorized by this roster read. Members
    /// whose profile is not active are omitted rather than represented by an
    /// internal user ID without displayable identity.
    public let publicIdentity: V2PublicIdentity

    public init(userID: UserID, role: V2RoomMembershipRole, publicIdentity: V2PublicIdentity) {
        self.userID = userID
        self.role = role
        self.publicIdentity = publicIdentity
    }
}

public struct V2RoomMembershipDirectoryPage: Equatable, Sendable {
    public let roomID: RoomID
    public let membershipRevision: UInt64
    /// Repeated on every page, so a management UI does not need to enumerate
    /// a large roster merely to discover its authenticated actor's role.
    public let actorRole: V2RoomMembershipRole
    public let entries: [V2RoomMembershipDirectoryEntry]
    /// Opaque to callers. It binds the seek boundary to this room and one
    /// membership revision, so pages from changing rosters are never mixed.
    public let nextCursor: String?

    public init(roomID: RoomID, membershipRevision: UInt64, actorRole: V2RoomMembershipRole, entries: [V2RoomMembershipDirectoryEntry], nextCursor: String?) {
        self.roomID = roomID
        self.membershipRevision = membershipRevision
        self.actorRole = actorRole
        self.entries = entries
        self.nextCursor = nextCursor
    }
}

public struct V2RoomMembershipDirectoryRequest: Equatable, Sendable {
    public static let maximumPageSize = 100
    public static let maximumCursorBytes = 512

    public let roomID: RoomID
    public let actorUserID: UserID
    public let cursor: String?
    public let pageSize: Int

    public init(roomID: RoomID, actorUserID: UserID, cursor: String?, pageSize: Int) throws {
        let trimmedCursor = cursor?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pageSize > 0, pageSize <= Self.maximumPageSize,
              trimmedCursor.map({ !$0.isEmpty && $0.utf8.count <= Self.maximumCursorBytes }) ?? true
        else { throw V2RoomMembershipDirectoryError.invalidRequest }
        self.roomID = roomID
        self.actorUserID = actorUserID
        self.cursor = trimmedCursor
        self.pageSize = pageSize
    }
}

public protocol V2RoomMembershipDirectoryStore: Sendable {
    func list(_ request: V2RoomMembershipDirectoryRequest) async throws -> V2RoomMembershipDirectoryPage
}

/// The service keeps validation and authorization behind a narrow,
/// independently testable contract.  Gateway adapters must pass only the
/// authenticated actor identity; they never receive an unbounded roster.
public struct V2RoomMembershipDirectoryService: Sendable {
    private let store: any V2RoomMembershipDirectoryStore

    public init(store: any V2RoomMembershipDirectoryStore) {
        self.store = store
    }

    public func list(_ request: V2RoomMembershipDirectoryRequest) async throws -> V2RoomMembershipDirectoryPage {
        try await store.list(request)
    }
}

public enum V2RoomMembershipDirectoryError: Error, Equatable, Sendable {
    case invalidRequest
    case roomNotFound
    case actorNotMember
    case invalidCursor
    case revisionConflict(currentRevision: UInt64)
    case corruptPersistenceState
}
