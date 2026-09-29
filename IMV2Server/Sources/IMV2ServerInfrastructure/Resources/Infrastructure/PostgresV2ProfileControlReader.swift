import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// A batch can contain different viewers and contexts. Every SQL row carries
/// its own actor/device, and results return only to that request's continuation.
struct PostgresV2ProfileControlReader: Sendable {
    let database: any Database

    static func payload(_ requests: [V2ProfileControlRequest]) throws -> Data {
        try JSONEncoder().encode(requests.enumerated().flatMap { request, input in
            input.keys.enumerated().map { key, value in
                Input(request_ordinal: request, key_ordinal: key, actor_user_id: input.actor.rawValue,
                    device_id: input.device.rawValue, target_user_id: value.userID.rawValue)
            }
        })
    }

    func read(_ requests: [V2ProfileControlRequest], deadline: ContinuousClock.Instant) async throws
        -> [Result<V2ProfileControlSnapshot, any Error>] {
        guard !requests.isEmpty, requests.reduce(0, { $0 + $1.keys.count }) <= 100,
              let sql = database as? any SQLDatabase else { throw V2ProfileViewReadError.invalidRequest }
        for request in requests { try request.validate() }
        let encoded = try Self.payload(requests)
        guard encoded.count <= 64 * 1024 else { throw V2ProfileViewReadError.invalidRequest }
        try Task.checkCancellation()
        guard .now < deadline else { throw V2ProfileControlBatchError.deadlineExceeded }
        // The configured database session policy bounds statement/lock waits.
        // The batcher retains its execution slot until SQL actually returns,
        // even if every caller has cancelled or passed its own deadline.
        let rows = try await sql.raw("""
            WITH requested AS MATERIALIZED (
                SELECT * FROM jsonb_to_recordset(\(bind: String(decoding: encoded, as: UTF8.self))::jsonb)
                    AS input(request_ordinal integer, key_ordinal integer, actor_user_id uuid, device_id uuid, target_user_id uuid)
            ), identities AS MATERIALIZED (
                SELECT identity.request_ordinal, device.session_expires_at
                FROM (SELECT DISTINCT request_ordinal, actor_user_id, device_id FROM requested) identity
                JOIN im_v2.auth_devices device ON device.user_id=identity.actor_user_id AND device.device_id=identity.device_id
                JOIN im_v2.public_user_profiles actor ON actor.user_id=device.user_id AND actor.state='active'
                WHERE device.revoked_at IS NULL AND device.session_expires_at>statement_timestamp()
                  AND NOT EXISTS(SELECT 1 FROM im_v2.account_disables disabled WHERE disabled.user_id=device.user_id)
            )
            SELECT input.request_ordinal, input.key_ordinal AS ordinal,
                   identity.session_expires_at AS device_expires_at, statement_timestamp() AS observed_at,
                   profile.user_id, profile.public_handle, profile.display_name, profile.account_kind,
                   profile.state, profile.revision, profile.visibility_revision,
                   CASE WHEN avatar.owner_user_id=profile.user_id AND avatar.state='available'
                        THEN avatar.media_id ELSE NULL END AS avatar_media_id,
                   direct.room_id AS direct_room_id, direct.route_epoch AS direct_route_epoch,
                   direct.room_shard_id AS direct_shard_id,
                   (input.target_user_id=input.actor_user_id OR relationship.state IN ('pending','accepted')) IS TRUE AS relationship_allowed,
                   relationship.updated_at AS relationship_updated_at,
                   alias.owner_user_id AS alias_owner_user_id, alias.remark_name AS alias_remark_name, alias.revision AS alias_revision
            FROM requested input
            LEFT JOIN identities identity ON identity.request_ordinal=input.request_ordinal
            LEFT JOIN im_v2.public_user_profiles profile ON profile.user_id=input.target_user_id
              AND identity.session_expires_at IS NOT NULL
              AND NOT EXISTS(SELECT 1 FROM im_v2.user_blocks block
                  WHERE (block.blocker_user_id=input.actor_user_id AND block.blocked_user_id=input.target_user_id)
                     OR (block.blocker_user_id=input.target_user_id AND block.blocked_user_id=input.actor_user_id))
            LEFT JOIN im_v2.media_objects avatar ON avatar.media_id=profile.avatar_media_id
            LEFT JOIN im_v2.direct_room_owner_routes direct
              ON identity.session_expires_at IS NOT NULL
             AND direct.lower_user_id=LEAST(input.actor_user_id,input.target_user_id)
             AND direct.higher_user_id=GREATEST(input.actor_user_id,input.target_user_id)
            LEFT JOIN im_v2.user_relationships relationship
              ON identity.session_expires_at IS NOT NULL
             AND relationship.lower_user_id=LEAST(input.actor_user_id,input.target_user_id)
             AND relationship.higher_user_id=GREATEST(input.actor_user_id,input.target_user_id)
            LEFT JOIN im_v2.user_contact_aliases alias
              ON alias.owner_user_id=input.actor_user_id AND alias.target_user_id=profile.user_id
             AND profile.state='active' AND input.actor_user_id<>input.target_user_id
            ORDER BY input.request_ordinal,input.key_ordinal
            """).all(decoding: Row.self)
        guard rows.count == requests.reduce(0, { $0 + $1.keys.count }),
              try JSONEncoder().encode(rows).count <= 256 * 1024
        else { throw V2ProfileViewReadError.corruptPersistenceState }
        var offset = 0
        return try requests.enumerated().map { request, input in
            let slice = rows[offset..<(offset + input.keys.count)]
            offset += input.keys.count
            guard slice.enumerated().allSatisfy({ $0.element.requestOrdinal == request && $0.element.ordinal == $0.offset }),
                  let first = slice.first else { throw V2ProfileViewReadError.corruptPersistenceState }
            guard let expiry = first.deviceExpiresAt else { return .failure(V2MediaStoreError.downloadNotAuthorized) }
            guard expiry > first.observedAt, slice.allSatisfy({ $0.deviceExpiresAt == expiry && $0.observedAt == first.observedAt })
            else { throw V2ProfileViewReadError.corruptPersistenceState }
            do { return .success(.init(rows: try slice.map { try $0.facts() }, observedAt: first.observedAt, deviceExpiresAt: expiry)) }
            catch { return .failure(error) }
        }
    }

    private struct Input: Encodable {
        let request_ordinal: Int; let key_ordinal: Int
        let actor_user_id: String; let device_id: String; let target_user_id: String
    }
    private struct Row: Codable {
        let requestOrdinal: Int; let ordinal: Int; let deviceExpiresAt: Date?; let observedAt: Date
        let userID: UUID?; let publicHandle: String?; let displayName: String?; let accountKind: String?
        let state: String?; let revision: Int64?; let visibilityRevision: Int64?; let avatarMediaID: UUID?
        let directRoomID: UUID?; let directRouteEpoch: Int64?; let directShardID: String?
        let relationshipAllowed: Bool; let relationshipUpdatedAt: Date?
        let aliasOwnerUserID: UUID?; let aliasRemarkName: String?; let aliasRevision: Int64?
        enum CodingKeys: String, CodingKey {
            case ordinal, state, revision
            case aliasOwnerUserID = "alias_owner_user_id", aliasRemarkName = "alias_remark_name", aliasRevision = "alias_revision"
            case requestOrdinal = "request_ordinal", deviceExpiresAt = "device_expires_at", observedAt = "observed_at"
            case userID = "user_id", publicHandle = "public_handle", displayName = "display_name", accountKind = "account_kind"
            case visibilityRevision = "visibility_revision", avatarMediaID = "avatar_media_id", directRoomID = "direct_room_id"
            case directRouteEpoch = "direct_route_epoch", directShardID = "direct_shard_id"
            case relationshipAllowed = "relationship_allowed", relationshipUpdatedAt = "relationship_updated_at"
        }
        func facts() throws -> V2ProfileControlFacts {
            let view: V2ProfileView?
            if let userID {
                guard let publicHandle, let displayName, let kind = accountKind.flatMap(V2AccountKind.init(rawValue:)),
                      let state = state.flatMap(V2ProfileState.init(rawValue:)), let revision, let visibilityRevision,
                      revision > 0, visibilityRevision > 0,
                      let version = V2ProfileRevision(rawValue: UInt64(revision)),
                      let visibility = V2ProfileRevision(rawValue: UInt64(visibilityRevision))
                else { throw V2ProfileViewReadError.corruptPersistenceState }
                let id = UserID(uuid: userID)
                view = try .init(userID: id,
                    publicIdentity: state == .active ? .init(userID: id, handle: .init(publicHandle), displayName: displayName, accountKind: kind) : nil,
                    avatar: state == .active ? avatarMediaID.map { V2AvatarReference(mediaID: .init(uuid: $0)) } : nil,
                    state: state, revision: version, visibilityRevision: visibility)
            } else { view = nil }
            let contactAlias: V2ContactAlias?
            if let aliasOwnerUserID {
                guard let userID, let aliasRevision, aliasRevision > 0,
                      let version = V2ProfileRevision(rawValue: UInt64(aliasRevision)) else { throw V2ProfileViewReadError.corruptPersistenceState }
                contactAlias = try .init(ownerUserID: .init(uuid:aliasOwnerUserID), targetUserID:.init(uuid:userID),
                    remarkName:aliasRemarkName, revision:version)
            } else { contactAlias = nil }
            return .init(view: view, directRoomID: directRoomID, directRouteEpoch: directRouteEpoch, directShardID: directShardID,
                relationshipAllowed: relationshipAllowed, relationshipUpdatedAt: relationshipUpdatedAt, contactAlias:contactAlias)
        }
    }
}
