import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core
import SQLKit

/// 在已授权的读取轮次内，查询消息附件当前在房间中的可见性。
/// 媒体／控制域协调者还必须校验设备，并在会话交换前再次查询；
/// 这里的结果不是服务商授权。
struct PostgresV2RoomMediaAuthorizationAdapter: Sendable {
    private let database: any Database
    private let token: V2RoomActivationToken
    private let lifetime: V2RoomActivationLifetime
    let scope: V2RoomActivationWriteScope

    init(database: any Database, token: V2RoomActivationToken, lifetime: V2RoomActivationLifetime) throws {
        guard lifetime.token == token else { throw V2RoomCallFailure.notAccepted(.staleActivation) }
        self.lifetime = lifetime
        self.database = database
        self.token = token
        self.scope = try .init(tokens: [token])
    }

    func execute(_ query: V2RoomMediaAuthorizationQuery) async throws -> V2RoomMediaAuthorizationResult {
        guard query.roomID == token.roomID else {
            throw V2RoomActorStateError.activationChanged
        }
        switch query {
        case .resourceDirectory(let request):
            return try await resourceDirectory(request)
        case .groupAvatar(let request):
            return try await groupAvatar(request)
        case .profileVisibilityBatch(let request):
            return try await executeProfileVisibilityBatch([request])[0]
        case .resourceUpload(let request):
            return try await resourceUpload(request)
        case .messageVisibility(let request):
            guard let room = request.roomID.uuidValue,
                  let message = request.messageID.uuidValue,
                  let media = request.mediaID.uuidValue,
                  let actor = request.actorUserID.uuidValue else {
                throw V2MediaStoreError.downloadNotAuthorized
            }
            return try await ownedTransaction { transaction, validUntil in
                guard let sql = transaction as? any SQLDatabase else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                try await v2SetRoomActivationSQLTimeouts(.default, sql: sql)
                try await scope.require([room], sql: sql)
                let row = try await sql.raw("""
                    SELECT room.membership_revision, message.content_revision,
                           media.state_updated_at, media.upload_session_id
                    FROM im_v2.messages AS message
                    JOIN im_v2.rooms AS room ON room.room_id = message.room_id
                    JOIN im_v2.message_media_references AS reference
                      ON reference.message_id = message.message_id
                    JOIN im_v2.media_objects AS media ON media.media_id = reference.media_id
                    JOIN im_v2.resource_catalog AS resource ON resource.media_id = media.media_id
                      AND resource.home_kind = 'room' AND resource.home_id = room.room_id
                      AND resource.usage_kind = 'message_attachment'
                    JOIN im_v2.resource_blob_placements AS placement ON placement.media_id = resource.media_id
                      AND placement.generation = resource.generation AND placement.state = 'active'
                    WHERE message.message_id = \(bind: message) AND message.room_id = \(bind: room)
                      AND media.media_id = \(bind: media) AND media.state = 'available'
                      AND reference.revoked_at IS NULL AND message.withdrawn_at IS NULL
                      AND \(v2ForwardSourceVisibility(actorID: actor))
                    FOR SHARE OF message, media
                    """).first(decoding: V2ActorMessageMediaVisibilityRow.self)
                guard let row else { return .notVisible }
                guard row.membershipRevision >= 0, row.contentRevision > 0,
                      row.mediaUpdatedAt.timeIntervalSince1970.isFinite else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                return .visible(.init(roomID: request.roomID, messageID: request.messageID,
                    mediaID: request.mediaID, membershipRevision: UInt64(row.membershipRevision),
                    contentRevision: UInt64(row.contentRevision),
                    mediaUpdatedAt: row.mediaUpdatedAt, uploadSessionID: row.uploadSessionID))
            }
        }
    }

    func ownedTransaction<Value: Sendable>(
        _ body: @escaping @Sendable (any Database, ContinuousClock.Instant) async throws -> Value
    ) async throws -> Value {
        try await lifetime.withPin(deadline: V2RoomSQLDeadline.boundedTransactionDeadline()) { validUntil in
            try await V2RoomSQLDeadline.withDeadline(validUntil) {
                try await v2WithRoomScopedTransaction(database: database) { transaction in
                    try await body(transaction, validUntil)
                }
            }
        }
    }

    private func proofExpiry(observedAt: Date, validUntil: ContinuousClock.Instant) throws -> Date {
        let remaining = ContinuousClock.now.duration(to: validUntil).components
        let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
        guard seconds > 0, seconds <= 30 else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
        return observedAt.addingTimeInterval(seconds)
    }

    private func groupAvatar(_ request: V2ActorGroupAvatarVisibilityWire) async throws -> V2RoomMediaAuthorizationResult {
        guard let room = request.roomID.uuidValue, let actor = request.actorUserID.uuidValue else {
            throw V2RoomCallFailure.notAccepted(.invalidRequest)
        }
        return try await ownedTransaction { transaction, validUntil in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            try await v2SetRoomActivationSQLTimeouts(.default, sql: sql)
            try await scope.require([room], sql: sql)
            guard let row = try await sql.raw("""
                SELECT r.membership_revision, a.media_id, COALESCE(a.revision,0) AS avatar_revision,
                       c.generation, clock_timestamp() AS observed_at,
                       (g.owner_user_id=\(bind:actor) AND member.role='owner' AND r.frozen_at IS NULL) AS can_manage
                FROM im_v2.rooms r JOIN im_v2.group_rooms g USING(room_id)
                JOIN im_v2.room_memberships member ON member.room_id=r.room_id AND member.user_id=\(bind:actor)
                LEFT JOIN im_v2.resource_group_avatars a ON a.room_id=r.room_id
                LEFT JOIN im_v2.resource_catalog c ON c.media_id=a.media_id
                LEFT JOIN im_v2.media_objects m ON m.media_id=a.media_id
                WHERE r.room_id=\(bind:room) AND r.room_kind='group'
                  AND member.joined_revision<=r.membership_revision
                  AND (member.left_revision IS NULL OR member.left_revision>r.membership_revision)
                  AND (a.media_id IS NULL OR (c.home_kind='room' AND c.home_id=r.room_id AND c.usage_kind='group_avatar'
                    AND m.state='available' AND EXISTS(SELECT 1 FROM im_v2.resource_blob_placements p
                      WHERE p.media_id=c.media_id AND p.generation=c.generation AND p.state='active')
                    AND (SELECT count(*) FROM im_v2.resource_variants v WHERE v.media_id=c.media_id
                      AND v.generation=c.generation AND v.recipe='avatar' AND v.recipe_version=1
                      AND v.size IN (128,256) AND v.state='ready')=2))
                """).first(decoding: V2GroupAvatarRoomFactsRow.self) else { return .notVisible }
            guard row.membershipRevision >= 0, row.avatarRevision >= 0,
                  row.observedAt.timeIntervalSince1970.isFinite else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let expiry = try proofExpiry(observedAt: row.observedAt, validUntil: validUntil)
            return .groupAvatarVisible(.init(request: request, activation: token,
                membershipRevision: row.membershipRevision,
                state: try .init(roomID: request.roomID, mediaID: row.mediaID.map { .init(uuid: $0) },
                                 revision: UInt64(row.avatarRevision)),
                resourceGeneration: row.generation, canManage: row.canManage,
                observedAt: row.observedAt, activationExpiresAt: expiry))
        }
    }

    /// Only the local activation factory supplies a cohort of individually admitted user envelopes.
    /// Each viewer and target is evaluated in the same statement snapshot; no authorization cache.
    func executeProfileVisibilityBatch(_ requests: [V2ActorProfileVisibilityBatchWire]) async throws -> [V2RoomMediaAuthorizationResult] {
        guard let room = token.roomID.uuidValue, (1...100).contains(requests.count),
              requests.allSatisfy({ $0.roomID == token.roomID
                  && V2RoomRequest.mediaAuthorization(.profileVisibilityBatch($0)).profileVisibilityTargetCount != nil }),
              requests.reduce(0, { $0 + $1.targetUserIDs.count }) <= 100
        else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        let input = requests.enumerated().flatMap { ordinal, request in
            request.targetUserIDs.enumerated().map { targetOrdinal, target in
                V2ProfileRoomInput(ordinal: ordinal, targetOrdinal: targetOrdinal,
                    actor: request.actorUserID.rawValue, kind: request.roomKind.rawValue, target: target.rawValue)
            }
        }
        let encoded = try JSONEncoder().encode(input)
        guard encoded.count <= 64 * 1_024 else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        let payload = String(decoding: encoded, as: UTF8.self)
        return try await ownedTransaction { transaction, validUntil in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            try await v2SetRoomActivationSQLTimeouts(.default, sql: sql)
            try await scope.require([room], sql: sql)
            let rows = try await sql.raw("""
                WITH requested AS MATERIALIZED (
                    SELECT * FROM jsonb_to_recordset(\(bind: payload)::jsonb)
                    AS x(ordinal integer, "targetOrdinal" integer, actor uuid, kind text, target uuid)
                )
                SELECT x.ordinal, x."targetOrdinal" AS target_ordinal, x.target,
                       room.membership_revision, room.group_permission_revision, statement_timestamp() AS observed_at,

                       visibility.allowed AS actor_visible,
                       (visibility.allowed AND CASE WHEN x.kind = 'groupJoinReview' THEN EXISTS (
                           SELECT 1 FROM im_v2.group_join_requests application
                           WHERE application.room_id=room.room_id AND application.applicant_user_id=x.target
                             AND application.state='pending'
                       ) ELSE member.user_id IS NOT NULL END) AS target_visible,
                       nickname.nickname, nickname.revision AS nickname_revision
                FROM im_v2.rooms room
                CROSS JOIN requested x
                LEFT JOIN im_v2.room_memberships actor ON actor.room_id = room.room_id AND actor.user_id = x.actor
                  AND actor.joined_revision <= room.membership_revision
                  AND (actor.left_revision IS NULL OR actor.left_revision > room.membership_revision)
                LEFT JOIN im_v2.room_memberships member ON member.room_id = room.room_id AND member.user_id = x.target
                  AND member.joined_revision <= room.membership_revision
                  AND (member.left_revision IS NULL OR member.left_revision > room.membership_revision)
                LEFT JOIN im_v2.room_member_nicknames nickname ON nickname.room_id = room.room_id AND nickname.user_id = member.user_id
                  AND room.room_kind = 'group' AND x.kind IN ('group','memberRoom') AND actor.user_id IS NOT NULL
                CROSS JOIN LATERAL (SELECT (actor.user_id IS NOT NULL AND CASE WHEN x.kind='groupJoinReview' THEN
                    room.room_kind='group' AND EXISTS(SELECT 1 FROM im_v2.group_rooms g WHERE g.room_id=room.room_id)
                    AND (actor.role='owner' OR EXISTS (
                        SELECT 1 FROM im_v2.group_role_permissions p
                        WHERE p.room_id=room.room_id AND p.role=actor.role AND p.permission='invite_members'
                    ) OR (actor.role='admin'
                        AND NOT EXISTS(SELECT 1 FROM im_v2.group_role_permissions p WHERE p.room_id=room.room_id AND p.role=actor.role)
                        AND NOT EXISTS(SELECT 1 FROM im_v2.group_role_policies p WHERE p.room_id=room.room_id AND p.role=actor.role)))
                    WHEN x.kind='memberRoom' THEN room.room_kind IN ('direct','group')
                    ELSE room.room_kind=x.kind END) IS TRUE AS allowed) visibility
                WHERE room.room_id = \(bind: room)
                ORDER BY x.ordinal, x."targetOrdinal"
                """).all(decoding: V2ProfileRoomLookupRow.self)
            guard rows.count == input.count, try JSONEncoder().encode(rows).count <= 256 * 1_024 else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            for (expected, row) in zip(input, rows) {
                guard row.ordinal == expected.ordinal, row.targetOrdinal == expected.targetOrdinal,
                      row.target == UUID(uuidString: expected.target), row.membershipRevision >= 0, row.permissionRevision >= 0,
                      row.observedAt.timeIntervalSince1970.isFinite,
                      !row.targetVisible || row.actorVisible else { throw V2RoomWriteStoreError.corruptPersistenceState }
            }
            let grouped = Dictionary(grouping: rows, by: \.ordinal)
            let results = try requests.enumerated().map { ordinal, request -> V2RoomMediaAuthorizationResult in
                guard let values = grouped[ordinal], let facts = values.first,
                      values.count == request.targetUserIDs.count,
                      values.allSatisfy({ $0.actorVisible == facts.actorVisible
                          && $0.observedAt == facts.observedAt && $0.membershipRevision == facts.membershipRevision
                          && $0.permissionRevision == facts.permissionRevision }) else { throw V2RoomWriteStoreError.corruptPersistenceState }
                guard facts.actorVisible else { return .notVisible }
                let expiry = try proofExpiry(observedAt: facts.observedAt, validUntil: validUntil)
                let members = try values.compactMap { row -> V2ActorGroupMemberPresentationWire? in
                    guard let revision = row.nicknameRevision else {
                        guard row.nickname == nil else { throw V2RoomWriteStoreError.corruptPersistenceState }
                        return nil
                    }
                    guard (request.roomKind == .group || request.roomKind == .memberRoom), row.targetVisible, revision > 0,
                          let revision = V2ProfileRevision(rawValue: UInt64(revision)) else {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                    let member = try V2GroupMemberPresentation(roomID: request.roomID, userID: .init(uuid: row.target),
                        groupNickname: row.nickname, revision: revision)
                    guard member.groupNickname == row.nickname else { throw V2RoomWriteStoreError.corruptPersistenceState }
                    return .init(member)
                }
                return .profilesVisible(.init(request: request, activation: token, membershipRevision: facts.membershipRevision,
                    visibleTargetUserIDs: values.filter(\.targetVisible).map { UserID(uuid: $0.target) },
                    observedAt: facts.observedAt, activationExpiresAt: expiry, groupMembers: members,
                    permissionRevision: facts.permissionRevision))
            }
            guard try JSONEncoder().encode(results).count <= 256 * 1_024 else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            return results
        }
    }

    private func resourceUpload(_ request: V2ActorResourceUploadAuthorizationWire) async throws -> V2RoomMediaAuthorizationResult {
        guard let room = request.roomID.uuidValue, let actor = request.actorUserID.uuidValue,
              request.usage.home(actorUserID: request.actorUserID) == .room(request.roomID)
        else { return .notVisible }
        return try await ownedTransaction { transaction, validUntil in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            try await scope.require([room], sql: sql)
            guard let row = try await sql.raw("""
                SELECT room.room_kind, room.frozen_at, room.membership_revision, room.group_permission_revision,
                       membership.role,  clock_timestamp() AS observed_at,
                       EXISTS (SELECT 1 FROM im_v2.group_rooms g WHERE g.room_id=room.room_id
                           AND g.owner_user_id=\(bind: actor)) AS structural_owner,
                       EXISTS (SELECT 1 FROM im_v2.room_member_mutes mute WHERE mute.room_id = room.room_id
                           AND mute.user_id = \(bind: actor) AND mute.mute_until > clock_timestamp()) AS muted
                FROM im_v2.rooms room JOIN im_v2.room_memberships membership ON membership.room_id = room.room_id
                WHERE room.room_id = \(bind: room) AND membership.user_id = \(bind: actor)
                  AND membership.joined_revision <= room.membership_revision
                  AND (membership.left_revision IS NULL OR membership.left_revision > room.membership_revision)
                """).first(decoding: V2ResourceUploadRoomAdmissionRow.self) else { return .notVisible }
            do {
                switch request.usage {
                case .messageAttachment:
                    try await v2AuthorizeContentWrite(roomID: room, isGroup: row.roomKind == "group", frozenAt: row.frozenAt,
                        actorIsActive: true, actorRole: row.role, isMuted: row.muted, sql: sql)
                case .groupAvatar:
                    // Until a group-profile permission exists, only structural ownership can admit this purpose.
                    guard row.roomKind == "group", row.role == "owner", row.structuralOwner,
                          row.frozenAt == nil else { return .notVisible }
                case .userAvatar: return .notVisible
                }
            } catch V2RoomWriteStoreError.actorNotEligible, V2RoomWriteStoreError.actorMuted, V2RoomWriteStoreError.roomFrozen {
                return .notVisible
            }
            guard row.observedAt.timeIntervalSince1970.isFinite else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let expiry = try proofExpiry(observedAt: row.observedAt, validUntil: validUntil)
            return .resourceUploadAllowed(.init(request: request, activation: token,
                membershipRevision: row.membershipRevision, permissionRevision: row.permissionRevision,
                role: row.role, observedAt: row.observedAt, activationExpiresAt: expiry))
        }
    }
}

extension PostgresV2RoomMediaAuthorizationAdapter: V2RoomMediaAuthorizationStoring {}

public extension V2RoomMediaAuthorizationDomainExecutor {
    init(database: any Database, token: V2RoomActivationToken, lifetime: V2RoomActivationLifetime) throws {
        self.init(token: token, store: try PostgresV2RoomMediaAuthorizationAdapter(database: database, token: token, lifetime: lifetime))
    }
}

private struct V2GroupAvatarRoomFactsRow: Decodable {
    let membershipRevision: Int64; let mediaID: UUID?; let avatarRevision: Int64; let generation: Int64?
    let observedAt: Date;  let canManage: Bool
    enum CodingKeys: String, CodingKey {
        case membershipRevision = "membership_revision", mediaID = "media_id", avatarRevision = "avatar_revision", generation
        case observedAt = "observed_at", canManage = "can_manage"
    }
}

private struct V2ProfileRoomInput: Encodable {
    let ordinal: Int; let targetOrdinal: Int; let actor: String; let kind: String; let target: String
}

private struct V2ProfileRoomLookupRow: Codable {
    let ordinal: Int; let targetOrdinal: Int; let target: UUID
    let actorVisible: Bool; let targetVisible: Bool
    let membershipRevision: Int64; let permissionRevision: Int64; let observedAt: Date
    let nickname: String?; let nicknameRevision: Int64?
    enum CodingKeys: String, CodingKey {
        case ordinal, target, targetOrdinal = "target_ordinal", actorVisible = "actor_visible", targetVisible = "target_visible"
        case membershipRevision = "membership_revision", permissionRevision = "group_permission_revision", observedAt = "observed_at"
        case nickname, nicknameRevision = "nickname_revision"
    }
}

private struct V2ResourceUploadRoomAdmissionRow: Decodable {
    let roomKind: String; let frozenAt: Date?; let membershipRevision: Int64; let permissionRevision: Int64
    let role: String;  let observedAt: Date; let muted: Bool
    let structuralOwner: Bool
    enum CodingKeys: String, CodingKey {
        case roomKind = "room_kind", frozenAt = "frozen_at", membershipRevision = "membership_revision"
        case permissionRevision = "group_permission_revision"
        case observedAt = "observed_at", role, muted
        case structuralOwner = "structural_owner"
    }
}

private struct V2ActorMessageMediaVisibilityRow: Decodable {
    let membershipRevision: Int64
    let contentRevision: Int64
    let mediaUpdatedAt: Date
    let uploadSessionID: UUID

    enum CodingKeys: String, CodingKey {
        case membershipRevision = "membership_revision"
        case contentRevision = "content_revision"
        case mediaUpdatedAt = "state_updated_at"
        case uploadSessionID = "upload_session_id"
    }
}
