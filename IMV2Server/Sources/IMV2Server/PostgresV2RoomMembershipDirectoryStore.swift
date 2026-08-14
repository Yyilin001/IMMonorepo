import Fluent
import Foundation
import IMV2Core
import SQLKit

/// Reads the current active-membership interval at one room revision. The
/// opaque cursor binds its UUID seek boundary to both room and revision,
/// keeping every page bounded without mixing two versions of a 100k roster.
public struct PostgresV2RoomMembershipDirectoryStore: V2RoomMembershipDirectoryStore {
    private let database: any Database

    public init(database: any Database) {
        self.database = database
    }

    public func list(_ request: V2RoomMembershipDirectoryRequest) async throws -> V2RoomMembershipDirectoryPage {
        let roomID = try directoryUUID(request.roomID)
        let actorID = try directoryUUID(request.actorUserID)
        let cursor = try request.cursor.map(directoryCursor)
        guard cursor?.roomID == nil || cursor?.roomID == roomID else {
            throw V2RoomMembershipDirectoryError.invalidCursor
        }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomMembershipDirectoryError.corruptPersistenceState }
            guard let room = try await sql.raw("""
                SELECT membership_revision FROM im_v2.rooms
                WHERE room_id = \(bind: roomID) AND room_kind = 'group'
                FOR SHARE
                """).first(decoding: DirectoryRoomRow.self)
            else { throw V2RoomMembershipDirectoryError.roomNotFound }
            guard room.membershipRevision >= 0 else { throw V2RoomMembershipDirectoryError.corruptPersistenceState }
            if let cursor, cursor.membershipRevision != room.membershipRevision {
                throw V2RoomMembershipDirectoryError.revisionConflict(currentRevision: UInt64(room.membershipRevision))
            }
            guard let actor = try await sql.raw("""
                SELECT role FROM im_v2.room_memberships
                WHERE room_id = \(bind: roomID) AND user_id = \(bind: actorID)
                  AND joined_revision <= \(bind: room.membershipRevision)
                  AND (left_revision IS NULL OR left_revision > \(bind: room.membershipRevision))
                """).first(decoding: DirectoryActorRow.self),
                  let actorRole = V2RoomMembershipRole(rawValue: actor.role)
            else { throw V2RoomMembershipDirectoryError.actorNotMember }

            let rows: [DirectoryMemberRow]
            if let cursor {
                rows = try await sql.raw("""
                    SELECT membership.user_id, membership.role,
                           profile.public_handle, profile.display_name
                    FROM im_v2.room_memberships AS membership
                    LEFT JOIN im_v2.public_user_profiles AS profile
                      ON profile.user_id = membership.user_id AND profile.state = 'active'
                    WHERE membership.room_id = \(bind: roomID)
                      AND membership.joined_revision <= \(bind: room.membershipRevision)
                      AND (membership.left_revision IS NULL OR membership.left_revision > \(bind: room.membershipRevision))
                      AND membership.user_id > \(bind: cursor.afterUserID)
                    ORDER BY membership.user_id
                    LIMIT \(bind: request.pageSize + 1)
                    """).all(decoding: DirectoryMemberRow.self)
            } else {
                rows = try await sql.raw("""
                    SELECT membership.user_id, membership.role,
                           profile.public_handle, profile.display_name
                    FROM im_v2.room_memberships AS membership
                    LEFT JOIN im_v2.public_user_profiles AS profile
                      ON profile.user_id = membership.user_id AND profile.state = 'active'
                    WHERE membership.room_id = \(bind: roomID)
                      AND membership.joined_revision <= \(bind: room.membershipRevision)
                      AND (membership.left_revision IS NULL OR membership.left_revision > \(bind: room.membershipRevision))
                    ORDER BY membership.user_id
                    LIMIT \(bind: request.pageSize + 1)
                    """).all(decoding: DirectoryMemberRow.self)
            }
            let hasMore = rows.count > request.pageSize
            let pageRows = Array(rows.prefix(request.pageSize))
            let entries = try pageRows.map { row -> V2RoomMembershipDirectoryEntry in
                guard let role = V2RoomMembershipRole(rawValue: row.role) else { throw V2RoomMembershipDirectoryError.corruptPersistenceState }
                let userID: UserID = try .init(row.userID.uuidString)
                let publicIdentity: V2PublicIdentity?
                switch (row.publicHandle, row.displayName) {
                case (.none, .none): publicIdentity = nil
                case let (.some(handle), .some(displayName)):
                    publicIdentity = try .init(userID: userID, handle: .init(handle), displayName: displayName)
                default: throw V2RoomMembershipDirectoryError.corruptPersistenceState
                }
                return .init(userID: userID, role: role, publicIdentity: publicIdentity)
            }
            let nextCursor: String? = if hasMore, let last = pageRows.last {
                try directoryCursorString(roomID: roomID, membershipRevision: room.membershipRevision, afterUserID: last.userID)
            } else {
                nil
            }
            return .init(
                roomID: request.roomID,
                membershipRevision: UInt64(room.membershipRevision),
                actorRole: actorRole,
                entries: entries,
                nextCursor: nextCursor
            )
        }
    }
}

private struct DirectoryRoomRow: Decodable {
    let membershipRevision: Int64
    enum CodingKeys: String, CodingKey { case membershipRevision = "membership_revision" }
}

private struct DirectoryMemberRow: Decodable {
    let userID: UUID
    let role: String
    let publicHandle: String?
    let displayName: String?
    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case role
        case publicHandle = "public_handle"
        case displayName = "display_name"
    }
}

private struct DirectoryActorRow: Decodable {
    let role: String
}

private struct DirectoryCursor: Codable {
    let version: Int
    let roomID: UUID
    let membershipRevision: Int64
    let afterUserID: UUID
}

private func directoryCursor(_ value: String) throws -> DirectoryCursor {
    guard let data = Data(base64Encoded: value),
          let cursor = try? JSONDecoder().decode(DirectoryCursor.self, from: data),
          cursor.version == 1,
          cursor.membershipRevision >= 0
    else { throw V2RoomMembershipDirectoryError.invalidCursor }
    return cursor
}

private func directoryCursorString(roomID: UUID, membershipRevision: Int64, afterUserID: UUID) throws -> String {
    let cursor = DirectoryCursor(version: 1, roomID: roomID, membershipRevision: membershipRevision, afterUserID: afterUserID)
    return try JSONEncoder().encode(cursor).base64EncodedString()
}

private func directoryUUID<Tag>(_ identifier: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag {
    guard let value = UUID(uuidString: identifier.rawValue) else { throw V2RoomMembershipDirectoryError.corruptPersistenceState }
    return value
}
