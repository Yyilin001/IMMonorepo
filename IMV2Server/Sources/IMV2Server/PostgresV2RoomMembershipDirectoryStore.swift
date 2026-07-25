import Fluent
import Foundation
import IMV2Core
import SQLKit

/// Reads the current active-membership interval at one room revision.  The
/// cursor is a UUID boundary, making the SQL seek-paginated and therefore
/// bounded even for a 100k-member room.
public struct PostgresV2RoomMembershipDirectoryStore: V2RoomMembershipDirectoryStore {
    private let database: any Database

    public init(database: any Database) {
        self.database = database
    }

    public func list(_ request: V2RoomMembershipDirectoryRequest) async throws -> V2RoomMembershipDirectoryPage {
        let roomID = try directoryUUID(request.roomID)
        let actorID = try directoryUUID(request.actorUserID)
        let cursor = try request.cursor.map { value -> UUID in
            guard let parsed = UUID(uuidString: value) else { throw V2RoomMembershipDirectoryError.invalidCursor }
            return parsed
        }
        guard let sql = database as? any SQLDatabase else { throw V2RoomMembershipDirectoryError.corruptPersistenceState }
        guard let room = try await sql.raw("""
            SELECT membership_revision FROM im_v2.rooms
            WHERE room_id = \(bind: roomID) AND room_kind = 'group'
            """).first(decoding: DirectoryRoomRow.self)
        else { throw V2RoomMembershipDirectoryError.roomNotFound }
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
                SELECT user_id, role FROM im_v2.room_memberships
                WHERE room_id = \(bind: roomID)
                  AND joined_revision <= \(bind: room.membershipRevision)
                  AND (left_revision IS NULL OR left_revision > \(bind: room.membershipRevision))
                  AND user_id > \(bind: cursor)
                ORDER BY user_id
                LIMIT \(bind: request.pageSize + 1)
                """).all(decoding: DirectoryMemberRow.self)
        } else {
            rows = try await sql.raw("""
                SELECT user_id, role FROM im_v2.room_memberships
                WHERE room_id = \(bind: roomID)
                  AND joined_revision <= \(bind: room.membershipRevision)
                  AND (left_revision IS NULL OR left_revision > \(bind: room.membershipRevision))
                ORDER BY user_id
                LIMIT \(bind: request.pageSize + 1)
                """).all(decoding: DirectoryMemberRow.self)
        }
        let hasMore = rows.count > request.pageSize
        let pageRows = hasMore ? Array(rows.dropLast()) : rows
        let entries = try pageRows.map { row -> V2RoomMembershipDirectoryEntry in
            guard let role = V2RoomMembershipRole(rawValue: row.role) else { throw V2RoomMembershipDirectoryError.corruptPersistenceState }
            return try .init(userID: .init(row.userID.uuidString), role: role)
        }
        guard room.membershipRevision >= 0 else { throw V2RoomMembershipDirectoryError.corruptPersistenceState }
        return .init(
            roomID: request.roomID,
            membershipRevision: UInt64(room.membershipRevision),
            actorRole: actorRole,
            entries: entries,
            nextCursor: hasMore ? pageRows.last?.userID.uuidString : nil
        )
    }
}

private struct DirectoryRoomRow: Decodable {
    let membershipRevision: Int64
    enum CodingKeys: String, CodingKey { case membershipRevision = "membership_revision" }
}

private struct DirectoryMemberRow: Decodable {
    let userID: UUID
    let role: String
    enum CodingKeys: String, CodingKey { case userID = "user_id"; case role }
}

private struct DirectoryActorRow: Decodable {
    let role: String
}

private func directoryUUID<Tag>(_ identifier: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag {
    guard let value = UUID(uuidString: identifier.rawValue) else { throw V2RoomMembershipDirectoryError.corruptPersistenceState }
    return value
}
