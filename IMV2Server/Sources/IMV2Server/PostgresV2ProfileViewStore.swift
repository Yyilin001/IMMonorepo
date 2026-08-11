import Fluent
import Foundation
import IMV2Core
import SQLKit

/// Authorizes each profile through a concrete direct-room or room-membership
/// context. It deliberately performs no group roster enumeration; each lookup
/// is bounded and backed by the active-membership indexes already used by the
/// room directory.
public struct PostgresV2ProfileViewStore: V2ProfileViewStore {
    private let database: any Database

    public init(database: any Database) {
        self.database = database
    }

    public func read(_ request: V2ProfileViewReadRequest) async throws -> [V2ProfileViewLookupResult] {
        guard let actorID = UUID(uuidString: request.actorUserID.rawValue) else {
            throw V2ProfileViewReadError.corruptPersistenceState
        }
        guard database is any SQLDatabase else {
            throw V2ProfileViewReadError.corruptPersistenceState
        }
        return try await database.transaction { transaction in
            guard let transactionSQL = transaction as? any SQLDatabase else {
                throw V2ProfileViewReadError.corruptPersistenceState
            }
            var results: [V2ProfileViewLookupResult] = []
            results.reserveCapacity(request.keys.count)
            for key in request.keys {
                try Task.checkCancellation()
                results.append(try await read(key: key, actorID: actorID, sql: transactionSQL))
            }
            return results
        }
    }

    private func read(
        key: V2ProfileViewLookupKey,
        actorID: UUID,
        sql: any SQLDatabase
    ) async throws -> V2ProfileViewLookupResult {
        guard let targetID = UUID(uuidString: key.userID.rawValue) else {
            throw V2ProfileViewReadError.corruptPersistenceState
        }
        let row: ProfileViewRow?
        switch key.context {
        case .directConversation:
            row = try await sql.raw("""
                SELECT p.user_id, p.public_handle, p.display_name, p.account_kind,
                       CASE WHEN avatar.owner_user_id = p.user_id AND avatar.state = 'available'
                            THEN avatar.media_id ELSE NULL END AS avatar_media_id,
                       p.state, p.revision, p.visibility_revision
                FROM im_v2.public_user_profiles AS p
                LEFT JOIN im_v2.media_objects AS avatar ON avatar.media_id = p.avatar_media_id
                WHERE p.user_id = \(bind: targetID)
                  AND EXISTS (
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
                     AND target_membership.user_id = \(bind: targetID)
                     AND target_membership.joined_revision <= room.membership_revision
                     AND (target_membership.left_revision IS NULL OR target_membership.left_revision > room.membership_revision)
                    WHERE (pair.lower_user_id = \(bind: actorID) AND pair.higher_user_id = \(bind: targetID))
                       OR (pair.higher_user_id = \(bind: actorID) AND pair.lower_user_id = \(bind: targetID))
                  )
                """).first(decoding: ProfileViewRow.self)
        case .relationship:
            // This lookup is deliberately bounded by the request's keys. It
            // authorizes only an existing bilateral relationship, so the
            // profile endpoint cannot become an internal-ID directory.
            row = try await sql.raw("""
                SELECT p.user_id, p.public_handle, p.display_name, p.account_kind,
                       CASE WHEN avatar.owner_user_id = p.user_id AND avatar.state = 'available'
                            THEN avatar.media_id ELSE NULL END AS avatar_media_id,
                       p.state, p.revision, p.visibility_revision
                FROM im_v2.public_user_profiles AS p
                LEFT JOIN im_v2.media_objects AS avatar ON avatar.media_id = p.avatar_media_id
                WHERE p.user_id = \(bind: targetID)
                  AND EXISTS (
                    SELECT 1
                    FROM im_v2.user_relationships AS relationship
                    WHERE relationship.state IN ('pending', 'accepted')
                      AND ((relationship.lower_user_id = \(bind: actorID)
                            AND relationship.higher_user_id = \(bind: targetID))
                        OR (relationship.higher_user_id = \(bind: actorID)
                            AND relationship.lower_user_id = \(bind: targetID)))
                  )
                """).first(decoding: ProfileViewRow.self)
        case .room(let roomID):
            guard let roomUUID = UUID(uuidString: roomID.rawValue) else {
                throw V2ProfileViewReadError.corruptPersistenceState
            }
            row = try await sql.raw("""
                SELECT p.user_id, p.public_handle, p.display_name, p.account_kind,
                       CASE WHEN avatar.owner_user_id = p.user_id AND avatar.state = 'available'
                            THEN avatar.media_id ELSE NULL END AS avatar_media_id,
                       p.state, p.revision, p.visibility_revision
                FROM im_v2.public_user_profiles AS p
                LEFT JOIN im_v2.media_objects AS avatar ON avatar.media_id = p.avatar_media_id
                INNER JOIN im_v2.rooms AS room
                  ON room.room_id = \(bind: roomUUID) AND room.room_kind = 'group'
                INNER JOIN im_v2.room_memberships AS actor_membership
                  ON actor_membership.room_id = room.room_id
                 AND actor_membership.user_id = \(bind: actorID)
                 AND actor_membership.joined_revision <= room.membership_revision
                 AND (actor_membership.left_revision IS NULL OR actor_membership.left_revision > room.membership_revision)
                INNER JOIN im_v2.room_memberships AS target_membership
                  ON target_membership.room_id = room.room_id
                 AND target_membership.user_id = \(bind: targetID)
                 AND target_membership.joined_revision <= room.membership_revision
                 AND (target_membership.left_revision IS NULL OR target_membership.left_revision > room.membership_revision)
                WHERE p.user_id = \(bind: targetID)
                """).first(decoding: ProfileViewRow.self)
        }
        guard let row else { return .unavailable(key: key) }
        return .profile(key: key, view: try row.profileView())
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
