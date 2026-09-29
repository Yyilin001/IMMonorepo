import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 在某个房间修订上读取可见的当前成员。
///
/// 每一条返回记录都必须具备有效的公开资料与未停用的账号；不可见或已停用的身份会被省略，
/// 而不会以只有内部标识的形式暴露。不透明游标保证每页有界，且不会把两个成员修订的页面混在一起。
public struct PostgresV2RoomMembershipDirectoryStore: V2RoomMembershipDirectoryStore {
    private let database: any Database

    /// 组合数据库。
    ///
    /// - Parameter database: 存放房间、成员关系与公开资料的数据库。
    public init(database: any Database) {
        self.database = database
    }

    /// 读取一页成员名录。
    ///
    /// 事务以共享锁读取房间当前成员修订；携带游标时要求游标修订与当前修订一致，
    /// 否则返回修订冲突而不混合两版数据。发起者必须是该修订下的当前成员。
    /// 查询按用户标识排序并多取一行以判断是否还有后续页，资料未生效或账号已停用的成员被过滤。
    ///
    /// - Parameter request: 已校验的查询请求。
    /// - Returns: 成员名录分页。
    /// - Throws: 游标房间不符或格式非法时抛出
    ///   ``V2RoomMembershipDirectoryError/invalidCursor``；房间不存在或非群聊时抛出
    ///   ``V2RoomMembershipDirectoryError/roomNotFound``；发起者不是当前成员时抛出
    ///   ``V2RoomMembershipDirectoryError/actorNotMember``；游标修订过期时抛出
    ///   ``V2RoomMembershipDirectoryError/revisionConflict(currentRevision:)``；
    ///   角色或账号类型无法解码时抛出
    ///   ``V2RoomMembershipDirectoryError/corruptPersistenceState``。
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
                           profile.public_handle, profile.display_name, profile.account_kind
                    FROM im_v2.room_memberships AS membership
                    JOIN im_v2.public_user_profiles AS profile
                      ON profile.user_id = membership.user_id AND profile.state = 'active'
                    WHERE membership.room_id = \(bind: roomID)
                      AND membership.joined_revision <= \(bind: room.membershipRevision)
                      AND (membership.left_revision IS NULL OR membership.left_revision > \(bind: room.membershipRevision))
                      AND membership.user_id > \(bind: cursor.afterUserID)
                      AND NOT EXISTS (
                          SELECT 1 FROM im_v2.account_disables AS disabled
                          WHERE disabled.user_id = membership.user_id
                      )
                    ORDER BY membership.user_id
                    LIMIT \(bind: request.pageSize + 1)
                    """).all(decoding: DirectoryMemberRow.self)
            } else {
                rows = try await sql.raw("""
                    SELECT membership.user_id, membership.role,
                           profile.public_handle, profile.display_name, profile.account_kind
                    FROM im_v2.room_memberships AS membership
                    JOIN im_v2.public_user_profiles AS profile
                      ON profile.user_id = membership.user_id AND profile.state = 'active'
                    WHERE membership.room_id = \(bind: roomID)
                      AND membership.joined_revision <= \(bind: room.membershipRevision)
                      AND (membership.left_revision IS NULL OR membership.left_revision > \(bind: room.membershipRevision))
                      AND NOT EXISTS (
                          SELECT 1 FROM im_v2.account_disables AS disabled
                          WHERE disabled.user_id = membership.user_id
                      )
                    ORDER BY membership.user_id
                    LIMIT \(bind: request.pageSize + 1)
                    """).all(decoding: DirectoryMemberRow.self)
            }
            let hasMore = rows.count > request.pageSize
            let pageRows = Array(rows.prefix(request.pageSize))
            let entries = try pageRows.map { row -> V2RoomMembershipDirectoryEntry in
                guard let role = V2RoomMembershipRole(rawValue: row.role) else { throw V2RoomMembershipDirectoryError.corruptPersistenceState }
                let userID: UserID = try .init(row.userID.uuidString)
                guard let accountKind = V2AccountKind(rawValue: row.accountKind) else {
                    throw V2RoomMembershipDirectoryError.corruptPersistenceState
                }
                let publicIdentity = try V2PublicIdentity(
                    userID: userID,
                    handle: .init(row.publicHandle),
                    displayName: row.displayName,
                    accountKind: accountKind
                )
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
    let publicHandle: String
    let displayName: String
    let accountKind: String
    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case role
        case publicHandle = "public_handle"
        case displayName = "display_name"
        case accountKind = "account_kind"
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

/// 解码成员名录游标。
///
/// - Parameter value: Base64 编码的游标字符串。
/// - Returns: 解码后的游标。
/// - Throws: 解码失败、版本不符或成员修订为负时抛出
///   ``V2RoomMembershipDirectoryError/invalidCursor``。
private func directoryCursor(_ value: String) throws -> DirectoryCursor {
    guard let data = Data(base64Encoded: value),
          let cursor = try? JSONDecoder().decode(DirectoryCursor.self, from: data),
          cursor.version == 1,
          cursor.membershipRevision >= 0
    else { throw V2RoomMembershipDirectoryError.invalidCursor }
    return cursor
}

/// 编码成员名录游标。
///
/// - Parameters:
///   - roomID: 目标房间。
///   - membershipRevision: 本页对应的成员修订。
///   - afterUserID: 下一页起始位置的前一条用户标识。
/// - Returns: Base64 编码的游标字符串。
/// - Throws: 编码失败时抛出。
private func directoryCursorString(roomID: UUID, membershipRevision: Int64, afterUserID: UUID) throws -> String {
    let cursor = DirectoryCursor(version: 1, roomID: roomID, membershipRevision: membershipRevision, afterUserID: afterUserID)
    return try JSONEncoder().encode(cursor).base64EncodedString()
}

/// 把标识原始值解析为 UUID。
///
/// - Parameter identifier: 已校验的标识类型。
/// - Returns: 对应的 UUID。
/// - Throws: 原始值不是合法 UUID 时抛出
///   ``V2RoomMembershipDirectoryError/corruptPersistenceState``。
private func directoryUUID<Tag>(_ identifier: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag {
    guard let value = UUID(uuidString: identifier.rawValue) else { throw V2RoomMembershipDirectoryError.corruptPersistenceState }
    return value
}
