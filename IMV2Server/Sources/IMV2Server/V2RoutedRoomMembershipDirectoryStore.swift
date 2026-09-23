import FluentKit
import Foundation
import IMV2Core
import SQLKit

struct V2RoomMemberCandidate: Equatable, Sendable {
    let userID: UserID
    let role: V2RoomMembershipRole
}

struct V2RoomMemberCandidatePage: Equatable, Sendable {
    let membershipRevision: UInt64
    let actorRole: V2RoomMembershipRole
    let entries: [V2RoomMemberCandidate]
    let nextCursor: String?
}

protocol V2RoomMemberCandidateReading: Sendable {
    func candidates(_ request: V2RoomMembershipDirectoryRequest, route: V2RoomShardRoute) async throws -> V2RoomMemberCandidatePage
    func validate(_ request: V2RoomMembershipDirectoryRequest, route: V2RoomShardRoute, page: V2RoomMemberCandidatePage) async throws
}

protocol V2MemberDirectoryIdentityReading: Sendable {
    func identities(for users: [UserID]) async throws -> [UserID: V2PublicIdentity]
}

/// 成员关系按房间归属读取，公开资料只由控制面提供。单次最多扫描一页候选。
public struct V2RoutedRoomMembershipDirectoryStore: V2RoomMembershipDirectoryStore {
    private let router: any V2RoomShardRouting
    private let owners: [String: any V2RoomMemberCandidateReading]
    private let identities: any V2MemberDirectoryIdentityReading

    /// 使用不缓存的控制面路由，并为各已配置 owner 构造有界名录读取器。
    public init(controlDatabase: any Database, ownerDatabases: [String: any Database]) throws {
        try self.init(router: V2PostgresRoomShardRouter(database: controlDatabase),
            owners: ownerDatabases.mapValues { PostgresV2RoomMembershipDirectoryStore(database: $0) },
            identities: PostgresV2MemberDirectoryIdentities(database: controlDatabase))
    }

    init(router: any V2RoomShardRouting, owners: [String: any V2RoomMemberCandidateReading],
         identities: any V2MemberDirectoryIdentityReading) throws {
        guard !owners.isEmpty, owners.keys.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw V2RoomShardStorageRegistryError.invalidLocation
        }
        self.router = router; self.owners = owners; self.identities = identities
    }

    public func list(_ request: V2RoomMembershipDirectoryRequest) async throws -> V2RoomMembershipDirectoryPage {
        try Task.checkCancellation()
        let route: V2RoomShardRoute
        do { route = try await router.route(for: request.roomID) }
        catch V2RoomShardRouteError.roomNotFound { throw V2RoomMembershipDirectoryError.roomNotFound }
        guard let owner = owners[route.shardID] else { throw V2RoomShardStorageRegistryError.unknownShardID }
        let page = try await owner.candidates(request, route: route)
        guard page.membershipRevision <= UInt64(Int64.max), page.entries.count <= request.pageSize,
              Set(page.entries.map(\.userID)).count == page.entries.count,
              page.nextCursor.map({ !$0.isEmpty && $0.utf8.count <= V2RoomMembershipDirectoryRequest.maximumCursorBytes && $0 != request.cursor }) ?? true
        else { throw V2RoomMembershipDirectoryError.corruptPersistenceState }
        try Task.checkCancellation()
        let profiles = try await identities.identities(for: page.entries.map(\.userID))
        var entries: [V2RoomMembershipDirectoryEntry] = []
        for candidate in page.entries {
            guard let identity = profiles[candidate.userID] else { continue }
            guard identity.userID == candidate.userID else { throw V2RoomMembershipDirectoryError.corruptPersistenceState }
            entries.append(.init(userID: candidate.userID, role: candidate.role, publicIdentity: identity))
        }
        // No database transaction is held across the control-plane read. Recheck
        // authorization and revision before publishing the materialized page.
        try Task.checkCancellation()
        try await owner.validate(request, route: route, page: page)
        do {
            guard try await router.route(for: request.roomID) == route else { throw V2RoomMembershipDirectoryError.ownerChanged }
        } catch V2RoomShardRouteError.roomNotFound { throw V2RoomMembershipDirectoryError.ownerChanged }
        try Task.checkCancellation()
        // Hidden/disabled profiles can make a page empty. Its owner cursor still
        // advances, so callers must allow empty pages with a new continuation.
        return .init(roomID: request.roomID, membershipRevision: page.membershipRevision,
            actorRole: page.actorRole, entries: entries, nextCursor: page.nextCursor)
    }
}

struct PostgresV2MemberDirectoryIdentities: V2MemberDirectoryIdentityReading {
    let database: any Database

    func identities(for users: [UserID]) async throws -> [UserID: V2PublicIdentity] {
        guard users.count <= V2RoomMembershipDirectoryRequest.maximumPageSize else { throw V2RoomMembershipDirectoryError.invalidRequest }
        guard !users.isEmpty else { return [:] }
        guard let sql = database as? any SQLDatabase, users.allSatisfy({ UUID(uuidString: $0.rawValue) != nil }) else {
            throw V2RoomMembershipDirectoryError.corruptPersistenceState
        }
        let encoded = String(decoding: try JSONEncoder().encode(users.map(\.rawValue)), as: UTF8.self)
        let rows = try await sql.raw("""
            SELECT profile.user_id, profile.public_handle, profile.display_name, profile.account_kind
            FROM im_v2.public_user_profiles AS profile
            JOIN jsonb_array_elements_text(\(bind: encoded)::jsonb) AS requested(user_id)
              ON profile.user_id = requested.user_id::uuid
            WHERE profile.state = 'active' AND NOT EXISTS (
                SELECT 1 FROM im_v2.account_disables AS disabled WHERE disabled.user_id = profile.user_id
            )
            """).all(decoding: DirectoryIdentityRow.self)
        var result: [UserID: V2PublicIdentity] = [:]
        for row in rows {
            let id = UserID(uuid: row.userID)
            guard let kind = V2AccountKind(rawValue: row.accountKind), result[id] == nil else { throw V2RoomMembershipDirectoryError.corruptPersistenceState }
            result[id] = try .init(userID: id, handle: .init(row.publicHandle), displayName: row.displayName, accountKind: kind)
        }
        return result
    }
}

private struct DirectoryIdentityRow: Decodable {
    let userID: UUID; let publicHandle: String; let displayName: String; let accountKind: String
    enum CodingKeys: String, CodingKey {
        case userID = "user_id", publicHandle = "public_handle", displayName = "display_name", accountKind = "account_kind"
    }
}
