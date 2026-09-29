import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 逐个资料通过具体的私聊房间或房间成员上下文进行授权。
///
/// 它刻意不做群名册枚举：每次查找都是有界的，并复用房间目录已经在用的当前成员索引。
public struct PostgresV2ProfileViewStore: V2ProfileViewStore {
    private let database: any Database

    /// 组合数据库。
    ///
    /// - Parameter database: 存放公开资料、房间与媒体对象的数据库。
    public init(database: any Database) {
        self.database = database
    }

    /// 按请求键读取资料视图。
    ///
    /// 请求键以 JSON 数组一次性传入，数据库按序返回每一项结果；无权限、被拉黑、
    /// 已删除或不存在的对象会被收敛为同一类结果，头像媒体仅在归属正确且可用时才返回。
    ///
    /// - Parameter request: 已校验的查询请求。
    /// - Returns: 与请求键一一对应的结果列表。
    /// - Throws: 用户标识无法解析、连接不支持 SQL 或返回行与请求数量不符时抛出
    ///   ``V2ProfileViewReadError/corruptPersistenceState``。
    public func read(_ request: V2ProfileViewReadRequest) async throws -> [V2ProfileViewLookupResult] {
        guard let actorID = UUID(uuidString: request.actorUserID.rawValue) else {
            throw V2ProfileViewReadError.corruptPersistenceState
        }
        guard let sql = database as? any SQLDatabase else {
            throw V2ProfileViewReadError.corruptPersistenceState
        }
        let inputs = try request.keys.enumerated().map(ProfileViewLookupInput.init)
        let encodedInputs = String(decoding: try JSONEncoder().encode(inputs), as: UTF8.self)
        let rows = try await sql.raw("""
            WITH requested AS (
                SELECT ordinal, target_user_id, context_kind, room_id
                FROM jsonb_to_recordset(\(bind: encodedInputs)::jsonb)
                    AS input(ordinal integer, target_user_id uuid, context_kind text, room_id uuid)
            ),
            authorized AS (
                SELECT input.ordinal, profile.user_id, profile.public_handle, profile.display_name,
                       profile.account_kind,
                       CASE WHEN avatar.owner_user_id = profile.user_id AND avatar.state = 'available'
                            THEN avatar.media_id ELSE NULL END AS avatar_media_id,
                       profile.state, profile.revision, profile.visibility_revision
                FROM requested AS input
                INNER JOIN im_v2.public_user_profiles AS profile ON profile.user_id = input.target_user_id
                LEFT JOIN im_v2.media_objects AS avatar ON avatar.media_id = profile.avatar_media_id
                WHERE NOT EXISTS (
                    SELECT 1 FROM im_v2.user_blocks AS block
                    WHERE (block.blocker_user_id = \(bind: actorID) AND block.blocked_user_id = input.target_user_id)
                       OR (block.blocker_user_id = input.target_user_id AND block.blocked_user_id = \(bind: actorID))
                )
                AND (
                    (input.context_kind = 'direct' AND EXISTS (
                        SELECT 1
                        FROM im_v2.direct_room_pairs AS pair
                        INNER JOIN im_v2.rooms AS room
                          ON room.room_id = pair.room_id AND room.room_kind = 'direct'
                        INNER JOIN im_v2.room_memberships AS actor_membership
                          ON actor_membership.room_id = pair.room_id
                         AND actor_membership.user_id = \(bind: actorID)
                         AND actor_membership.joined_revision <= room.membership_revision
                         AND (actor_membership.left_revision IS NULL OR actor_membership.left_revision > room.membership_revision)
                        INNER JOIN im_v2.room_memberships AS target_membership
                          ON target_membership.room_id = pair.room_id
                         AND target_membership.user_id = input.target_user_id
                         AND target_membership.joined_revision <= room.membership_revision
                         AND (target_membership.left_revision IS NULL OR target_membership.left_revision > room.membership_revision)
                        WHERE (pair.lower_user_id = \(bind: actorID) AND pair.higher_user_id = input.target_user_id)
                           OR (pair.higher_user_id = \(bind: actorID) AND pair.lower_user_id = input.target_user_id)
                    ))
                    OR (input.context_kind = 'relationship' AND EXISTS (
                        SELECT 1 FROM im_v2.user_relationships AS relationship
                        WHERE relationship.state IN ('pending', 'accepted')
                          AND ((relationship.lower_user_id = \(bind: actorID) AND relationship.higher_user_id = input.target_user_id)
                            OR (relationship.higher_user_id = \(bind: actorID) AND relationship.lower_user_id = input.target_user_id))
                    ))
                    OR (input.context_kind = 'room' AND EXISTS (
                        SELECT 1
                        FROM im_v2.rooms AS room
                        INNER JOIN im_v2.room_memberships AS actor_membership
                          ON actor_membership.room_id = room.room_id
                         AND actor_membership.user_id = \(bind: actorID)
                         AND actor_membership.joined_revision <= room.membership_revision
                         AND (actor_membership.left_revision IS NULL OR actor_membership.left_revision > room.membership_revision)
                        INNER JOIN im_v2.room_memberships AS target_membership
                          ON target_membership.room_id = room.room_id
                         AND target_membership.user_id = input.target_user_id
                         AND target_membership.joined_revision <= room.membership_revision
                         AND (target_membership.left_revision IS NULL OR target_membership.left_revision > room.membership_revision)
                        WHERE room.room_id = input.room_id AND room.room_kind = 'group'
                    ))
                )
            )
            SELECT requested.ordinal,
                   authorized.user_id, authorized.public_handle, authorized.display_name,
                   authorized.account_kind, authorized.avatar_media_id, authorized.state,
                   authorized.revision, authorized.visibility_revision
            FROM requested
            LEFT JOIN authorized ON authorized.ordinal = requested.ordinal
            ORDER BY requested.ordinal
            """).all(decoding: BatchProfileViewRow.self)
        guard rows.count == request.keys.count else {
            throw V2ProfileViewReadError.corruptPersistenceState
        }
        return try rows.enumerated().map { expectedOrdinal, row in
            guard row.ordinal == expectedOrdinal else {
                throw V2ProfileViewReadError.corruptPersistenceState
            }
            let key = request.keys[expectedOrdinal]
            guard let profile = try row.profileView() else { return .unavailable(key: key) }
            return .profile(key: key, view: profile)
        }
    }
}

private struct ProfileViewLookupInput: Encodable {
    let ordinal: Int
    let targetUserID: String
    let contextKind: String
    let roomID: String?

    init(offset: Int, element key: V2ProfileViewLookupKey) throws {
        ordinal = offset
        targetUserID = key.userID.rawValue
        switch key.context {
        case .directConversation:
            contextKind = "direct"
            roomID = nil
        case .relationship:
            contextKind = "relationship"
            roomID = nil
        case .room(let roomID):
            contextKind = "room"
            self.roomID = roomID.rawValue
        case .groupJoinReview:
            throw V2ProfileViewReadError.invalidRequest
        }
    }

    enum CodingKeys: String, CodingKey {
        case ordinal
        case targetUserID = "target_user_id"
        case contextKind = "context_kind"
        case roomID = "room_id"
    }
}

private struct BatchProfileViewRow: Decodable {
    let ordinal: Int
    let userID: UUID?
    let publicHandle: String?
    let displayName: String?
    let accountKind: String?
    let avatarMediaID: UUID?
    let state: String?
    let revision: Int64?
    let visibilityRevision: Int64?

    enum CodingKeys: String, CodingKey {
        case ordinal
        case userID = "user_id"
        case publicHandle = "public_handle"
        case displayName = "display_name"
        case accountKind = "account_kind"
        case avatarMediaID = "avatar_media_id"
        case state
        case revision
        case visibilityRevision = "visibility_revision"
    }

    func profileView() throws -> V2ProfileView? {
        if userID == nil, publicHandle == nil, displayName == nil,
           accountKind == nil, state == nil, revision == nil,
           visibilityRevision == nil, avatarMediaID == nil {
            return nil
        }
        guard let userID, let publicHandle, let displayName, let accountKind,
              let state, let revision, let visibilityRevision
        else { throw V2ProfileViewReadError.corruptPersistenceState }
        return try ProfileViewRow(
            userID: userID,
            publicHandle: publicHandle,
            displayName: displayName,
            accountKind: accountKind,
            avatarMediaID: avatarMediaID,
            state: state,
            revision: revision,
            visibilityRevision: visibilityRevision
        ).profileView()
    }
}

private struct ProfileViewRow: Decodable {
    let userID: UUID
    let publicHandle: String
    let displayName: String
    let accountKind: String
    let avatarMediaID: UUID?
    let state: String
    let revision: Int64
    let visibilityRevision: Int64

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case publicHandle = "public_handle"
        case displayName = "display_name"
        case accountKind = "account_kind"
        case avatarMediaID = "avatar_media_id"
        case state
        case revision
        case visibilityRevision = "visibility_revision"
    }

    func profileView() throws -> V2ProfileView {
        guard revision > 0, visibilityRevision > 0,
              let state = V2ProfileState(rawValue: state),
              let accountKind = V2AccountKind(rawValue: accountKind),
              let profileRevision = V2ProfileRevision(rawValue: UInt64(revision)),
              let accessRevision = V2ProfileRevision(rawValue: UInt64(visibilityRevision))
        else { throw V2ProfileViewReadError.corruptPersistenceState }
        let userID = try UserID(userID.uuidString)
        switch state {
        case .active:
            return try .init(
                userID: userID,
                publicIdentity: .init(userID: userID, handle: .init(publicHandle), displayName: displayName, accountKind: accountKind),
                avatar: try avatarMediaID.map { try V2AvatarReference(mediaID: .init($0.uuidString)) },
                state: state,
                revision: profileRevision,
                visibilityRevision: accessRevision
            )
        case .deleted, .suspended, .hidden:
            return try .init(
                userID: userID,
                publicIdentity: nil,
                avatar: nil,
                state: state,
                revision: profileRevision,
                visibilityRevision: accessRevision
            )
        }
    }
}
