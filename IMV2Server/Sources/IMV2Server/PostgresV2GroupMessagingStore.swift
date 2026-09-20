import Fluent
import Foundation
import IMV2Core
import SQLKit

/// PostgreSQL 群引导事务。
///
/// 它在同一事务内创建房间、初始成员关系、准入状态、个人会话发现待办与操作台账。
/// 分阶段受众在整个事务中始终保持关系形态，因此十万成员群不会变成 Swift 数组
/// 或一个巨大的 PostgreSQL 参数数组。
public struct PostgresV2GroupMessagingStore:
    V2GroupMessagingStore,
    V2ControlValidatedGroupMessagingStore,
    V2ControlValidatedStagedGroupMessagingStore,
    V2StagedGroupMessagingStore
{
    private let database: any Database

    /// 组合数据库与新建群聊的权威副本形态策略。
    ///
    /// 混合大群固定以房间日志为权威副本；标准群取这里的部署策略，默认与部署默认一致
    /// （`room_log`），兼容基线必须显式传 `fanout`。单聊不使用该参数，它由部署开关决定。
    ///
    /// - Parameters:
    ///   - database: 存放房间、事件与投递的数据库。
    public init(database: any Database) {
        self.database = database
    }

    public func create(
        command: V2CreateGroupRoomCommand,
        capacityProfile: V2CapacityProfile,
        roomShardID: String,
        roomID: RoomID,
        eventID: EventID,
        now: Date
    ) async throws -> V2CreateGroupRoomOutcome {
        let actorID = try groupUUID(command.actorUserID)
        let requestedMembers = try command.initialMemberUserIDs.map(groupUUID)
        let memberCount = requestedMembers.count + 1
        guard memberCount <= capacityProfile.limits.maxEligibleMembers else {
            return .memberLimitReached
        }
        let input = GroupCreationInput(
            actorUserID: command.actorUserID,
            actorID: actorID,
            operationID: try groupUUID(command.operationID),
            title: command.title,
            capacityClass: command.capacityClass,
            memberCount: memberCount,
            audience: .inline(
                requestedMembers: requestedMembers,
                materializedMembers: command.allMemberUserIDs
            )
        )
        return try await createGroup(
            input: input,
            identityValidation: .ownerDatabase,
            capacityProfile: capacityProfile,
            roomShardID: roomShardID,
            roomID: roomID,
            eventID: eventID,
            now: now
        )
    }

    public func createControlValidated(
        command: V2CreateGroupRoomCommand,
        validatedMemberUserIDs: [UserID],
        capacityProfile: V2CapacityProfile,
        roomShardID: String,
        roomID: RoomID,
        eventID: EventID,
        now: Date
    ) async throws -> V2CreateGroupRoomOutcome {
        let actorID = try groupUUID(command.actorUserID)
        let requestedMembers = try command.initialMemberUserIDs.map(groupUUID)
        let canonicalAudience = validatedMemberUserIDs.sorted()
        guard canonicalAudience == command.allMemberUserIDs,
              canonicalAudience.count <= capacityProfile.limits.maxEligibleMembers
        else { throw V2GroupMessagingStoreError.corruptPersistenceState }
        return try await createGroup(
            input: .init(
                actorUserID: command.actorUserID,
                actorID: actorID,
                operationID: try groupUUID(command.operationID),
                title: command.title,
                capacityClass: command.capacityClass,
                memberCount: canonicalAudience.count,
                audience: .inline(
                    requestedMembers: requestedMembers,
                    materializedMembers: canonicalAudience
                )
            ),
            identityValidation: .controlDatabaseManifest,
            capacityProfile: capacityProfile,
            roomShardID: roomShardID,
            roomID: roomID,
            eventID: eventID,
            now: now
        )
    }

    public func stageControlValidatedAudience(
        intent: V2GroupRoomCreationIntent,
        page: V2GroupRoomCreationManifestPage,
        now: Date
    ) async throws {
        guard v2PostgresTimestampCanEncode(now) else { throw V2GroupMessagingStoreError.corruptPersistenceState }
        let values = try GroupOwnerIntentValues(intent)
        let encodedMembers = try groupUUIDJSON(
            page.memberUserIDs.map { userID in
                guard let value = userID.uuidValue else {
                    throw V2GroupMessagingStoreError.corruptPersistenceState
                }
                return value
            }
        )
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2GroupMessagingStoreError.corruptPersistenceState
            }
            let lockKey = values.actorUserID.uuidString
                + ":" + values.operationID.uuidString
            try await sql.raw("""
                SELECT pg_advisory_xact_lock(
                    hashtextextended(\(bind: lockKey), 0)
                )
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.group_room_creation_intents
                    (actor_user_id, operation_id, room_id, event_id,
                     room_shard_id, route_epoch, request_fingerprint,
                     audience_member_count, state, created_at, updated_at)
                VALUES (
                    \(bind: values.actorUserID), \(bind: values.operationID),
                    \(bind: values.roomID), \(bind: values.eventID),
                    \(bind: intent.roomShardID),
                    \(bind: intent.routeEpoch),
                    \(bind: intent.requestFingerprint),
                    \(bind: intent.audienceMemberCount), 'prepared',
                    \(bind: now), \(bind: now)
                )
                ON CONFLICT DO NOTHING
                """).run()
            guard let persisted = try await sql.raw("""
                SELECT room_id, event_id, room_shard_id, route_epoch,
                       request_fingerprint, audience_member_count
                FROM im_v2.group_room_creation_intents
                WHERE actor_user_id = \(bind: values.actorUserID)
                  AND operation_id = \(bind: values.operationID)
                FOR UPDATE
                """).first(decoding: GroupOwnerIntentRow.self),
                  persisted.matches(intent)
            else { throw V2GroupRoomCreationIntentStoreError.routeConflict }

            try await sql.raw("""
                INSERT INTO im_v2.group_room_creation_intent_pages
                    (actor_user_id, operation_id, page_number, member_count,
                     page_digest, is_final, created_at)
                VALUES (
                    \(bind: values.actorUserID), \(bind: values.operationID),
                    \(bind: page.pageNumber),
                    \(bind: page.memberUserIDs.count), \(bind: page.digest),
                    \(bind: page.isFinal), \(bind: now)
                )
                ON CONFLICT DO NOTHING
                """).run()
            guard let persistedPage = try await sql.raw("""
                SELECT member_count, page_digest, is_final
                FROM im_v2.group_room_creation_intent_pages
                WHERE actor_user_id = \(bind: values.actorUserID)
                  AND operation_id = \(bind: values.operationID)
                  AND page_number = \(bind: page.pageNumber)
                """).first(decoding: GroupOwnerIntentPageRow.self),
                  persistedPage.memberCount == page.memberUserIDs.count,
                  persistedPage.pageDigest == page.digest,
                  persistedPage.isFinal == page.isFinal
            else { throw V2GroupRoomCreationIntentStoreError.routeConflict }
            try await sql.raw("""
                INSERT INTO im_v2.group_room_creation_intent_members
                    (actor_user_id, operation_id, user_id, created_at)
                SELECT \(bind: values.actorUserID),
                       \(bind: values.operationID), value::uuid, \(bind: now)
                FROM jsonb_array_elements_text(
                    \(bind: encodedMembers)::jsonb
                ) AS value
                ON CONFLICT DO NOTHING
                """).run()
        }
    }

    public func createControlValidatedStaged(
        command: V2StagedGroupRoomCommand,
        intent: V2GroupRoomCreationIntent,
        capacityProfile: V2CapacityProfile,
        now: Date
    ) async throws -> V2CreateGroupRoomOutcome {
        guard command.actorUserID == intent.actorUserID,
              command.operationID == intent.operationID,
              command.allMemberCount == intent.audienceMemberCount,
              command.allMemberCount <= capacityProfile.limits.maxEligibleMembers
        else { throw V2GroupMessagingStoreError.corruptPersistenceState }
        return try await createGroup(
            input: .init(
                actorUserID: command.actorUserID,
                actorID: try groupUUID(command.actorUserID),
                operationID: try groupUUID(command.operationID),
                title: command.title,
                capacityClass: command.capacityClass,
                memberCount: command.allMemberCount,
                audience: .stagedControlManifest
            ),
            identityValidation: .controlDatabaseManifest,
            capacityProfile: capacityProfile,
            roomShardID: intent.roomShardID,
            roomID: intent.roomID,
            eventID: intent.eventID,
            now: now
        )
    }

    public func createStaged(
        command: V2StagedGroupRoomCommand,
        capacityProfile: V2CapacityProfile,
        roomShardID: String,
        roomID: RoomID,
        eventID: EventID,
        now: Date
    ) async throws -> V2CreateGroupRoomOutcome {
        guard command.allMemberCount <= capacityProfile.limits.maxEligibleMembers else {
            return .memberLimitReached
        }
        let input = GroupCreationInput(
            actorUserID: command.actorUserID,
            actorID: try groupUUID(command.actorUserID),
            operationID: try groupUUID(command.operationID),
            title: command.title,
            capacityClass: command.capacityClass,
            memberCount: command.allMemberCount,
            audience: .staged
        )
        return try await createGroup(
            input: input,
            identityValidation: .ownerDatabase,
            capacityProfile: capacityProfile,
            roomShardID: roomShardID,
            roomID: roomID,
            eventID: eventID,
            now: now
        )
    }

    private func createGroup(
        input: GroupCreationInput,
        identityValidation: GroupCreationIdentityValidation,
        capacityProfile: V2CapacityProfile,
        roomShardID: String,
        roomID: RoomID,
        eventID: EventID,
        now: Date
    ) async throws -> V2CreateGroupRoomOutcome {
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2GroupMessagingStoreError.corruptPersistenceState
            }
            let operationLockKey = input.actorID.uuidString + ":" + input.operationID.uuidString
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: operationLockKey), 0))").run()

            if let previous = try await sql.raw("""
                SELECT room_id, title, capacity_class, audience_kind,
                       initial_member_count, initial_member_user_ids, created_at
                FROM im_v2.group_room_operations
                WHERE actor_user_id = \(bind: input.actorID)
                  AND operation_id = \(bind: input.operationID)
                """).first(decoding: GroupOperationRow.self) {
                guard previous.matches(input) else { return .idempotencyConflict }
                return .idempotent(try previous.group(ownerUserID: input.actorUserID))
            }

            guard v2PostgresTimestampCanEncode(now) else {
                throw V2GroupMessagingStoreError.corruptPersistenceState
            }
            switch (input.audience, identityValidation) {
            case (.inline, .controlDatabaseManifest):
                // The routed coordinator can reach this capability only with
                // the immutable audience returned by the durable control
                // intent. Repeating identity lookups here would require a
                // synchronously replicated global profile database and would
                // reintroduce a cross-store race.
                break

            case (.inline(let requestedMembers, _), .ownerDatabase):
                let allMembers = [input.actorID] + requestedMembers
                let encoded = try groupUUIDJSON(allMembers)
                let activeMemberCount = try await sql.raw("""
                    WITH requested AS (
                        SELECT value::uuid AS user_id
                        FROM jsonb_array_elements_text(\(bind: encoded)::jsonb) AS value
                    )
                    SELECT COUNT(*)::bigint AS value
                    FROM requested
                    INNER JOIN im_v2.public_user_profiles AS profile
                      ON profile.user_id = requested.user_id AND profile.state = 'active'
                    LEFT JOIN im_v2.account_disables AS disabled
                      ON disabled.user_id = requested.user_id
                    WHERE disabled.user_id IS NULL
                    """).first(decoding: GroupCountRow.self)?.value ?? -1
                guard activeMemberCount == Int64(input.memberCount) else { return .invalidMembers }

            case (.staged, .ownerDatabase):
                guard let draft = try await sql.raw("""
                    SELECT draft.title, draft.state,
                           (SELECT COUNT(*)::bigint
                            FROM im_v2.group_room_creation_draft_members AS member
                            WHERE member.actor_user_id = draft.actor_user_id
                              AND member.operation_id = draft.operation_id) AS member_count
                    FROM im_v2.group_room_creation_drafts AS draft
                    WHERE draft.actor_user_id = \(bind: input.actorID)
                      AND draft.operation_id = \(bind: input.operationID)
                    FOR SHARE
                    """).first(decoding: GroupStagedDraftRow.self),
                      draft.state == "finalizing",
                      draft.title == input.title,
                      draft.memberCount == Int64(input.memberCount - 1)
                else { return .idempotencyConflict }

                let activeMemberCount = try await sql.raw("""
                    WITH requested AS (
                        SELECT \(bind: input.actorID) AS user_id
                        UNION ALL
                        SELECT member.user_id
                        FROM im_v2.group_room_creation_draft_members AS member
                        WHERE member.actor_user_id = \(bind: input.actorID)
                          AND member.operation_id = \(bind: input.operationID)
                    )
                    SELECT COUNT(*)::bigint AS value
                    FROM requested
                    INNER JOIN im_v2.public_user_profiles AS profile
                      ON profile.user_id = requested.user_id AND profile.state = 'active'
                    LEFT JOIN im_v2.account_disables AS disabled
                      ON disabled.user_id = requested.user_id
                    WHERE disabled.user_id IS NULL
                    """).first(decoding: GroupCountRow.self)?.value ?? -1
                guard activeMemberCount == Int64(input.memberCount) else { return .invalidMembers }

            case (.staged, .controlDatabaseManifest):
                throw V2GroupMessagingStoreError.corruptPersistenceState

            case (.stagedControlManifest, .ownerDatabase):
                throw V2GroupMessagingStoreError.corruptPersistenceState

            case (.stagedControlManifest, .controlDatabaseManifest):
                guard let summary = try await sql.raw("""
                    SELECT
                        COUNT(*)::bigint AS page_count,
                        COALESCE(MIN(page_number), -1)::bigint AS minimum_page,
                        COALESCE(MAX(page_number), -1)::bigint AS maximum_page,
                        COALESCE(SUM(member_count), 0)::bigint AS declared_members,
                        COUNT(*) FILTER (WHERE is_final)::bigint AS final_count,
                        COALESCE(MAX(page_number) FILTER (WHERE is_final), -1)::bigint
                            AS final_page,
                        (SELECT COUNT(*)::bigint
                         FROM im_v2.group_room_creation_intent_members AS member
                         WHERE member.actor_user_id = \(bind: input.actorID)
                           AND member.operation_id = \(bind: input.operationID)
                        ) AS materialized_members
                    FROM im_v2.group_room_creation_intent_pages
                    WHERE actor_user_id = \(bind: input.actorID)
                      AND operation_id = \(bind: input.operationID)
                    """).first(decoding: GroupOwnerManifestSummaryRow.self),
                      summary.pageCount > 0,
                      summary.minimumPage == 0,
                      summary.maximumPage == summary.pageCount - 1,
                      summary.finalCount == 1,
                      summary.finalPage == summary.maximumPage,
                      summary.declaredMembers == Int64(input.memberCount),
                      summary.materializedMembers == Int64(input.memberCount)
                else { return .unavailable }
            }

            let createdRoomID = try groupUUID(roomID)
            let createdEventID = try groupUUID(eventID)
            // Responses and projections use the persisted precision. Other writes keep the original Date.
            guard let timestamp = try await sql.raw("""
                INSERT INTO im_v2.rooms
                    (room_id, room_kind, room_shard_id, room_sequence, membership_revision,
                     capacity_profile_id, capacity_class, created_at)
                VALUES (\(bind: createdRoomID), 'group', \(bind: roomShardID), 1, 1,
                        \(bind: capacityProfile.id), \(bind: input.capacityClass.rawValue),
                        \(bind: now))
                RETURNING created_at
                """).first(decoding: GroupCommittedTimestampRow.self) else {
                throw V2GroupMessagingStoreError.corruptPersistenceState
            }
            let createdAtMilliseconds = try v2GatewayMilliseconds(timestamp.createdAt)
            try await sql.raw("""
                INSERT INTO im_v2.group_rooms (room_id, owner_user_id, title, created_at)
                VALUES (\(bind: createdRoomID), \(bind: input.actorID), \(bind: input.title), \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_memberships (room_id, user_id, role, joined_revision)
                VALUES (\(bind: createdRoomID), \(bind: input.actorID), 'owner', 1)
                """).run()

            switch input.audience {
            case .inline(let requestedMembers, _):
                if !requestedMembers.isEmpty {
                    let encoded = try groupUUIDJSON(requestedMembers)
                    try await sql.raw("""
                        INSERT INTO im_v2.room_memberships (room_id, user_id, role, joined_revision)
                        SELECT \(bind: createdRoomID), value::uuid, 'member', 1
                        FROM jsonb_array_elements_text(\(bind: encoded)::jsonb) AS value
                        """).run()
                }
            case .staged:
                try await sql.raw("""
                    INSERT INTO im_v2.room_memberships (room_id, user_id, role, joined_revision)
                    SELECT \(bind: createdRoomID), member.user_id, 'member', 1
                    FROM im_v2.group_room_creation_draft_members AS member
                    WHERE member.actor_user_id = \(bind: input.actorID)
                      AND member.operation_id = \(bind: input.operationID)
                    """).run()
            case .stagedControlManifest:
                try await sql.raw("""
                    INSERT INTO im_v2.room_memberships
                        (room_id, user_id, role, joined_revision)
                    SELECT \(bind: createdRoomID), member.user_id, 'member', 1
                    FROM im_v2.group_room_creation_intent_members AS member
                    WHERE member.actor_user_id = \(bind: input.actorID)
                      AND member.operation_id = \(bind: input.operationID)
                    AND member.user_id <> \(bind: input.actorID)
                    """).run()
            }

            // Every active member of a room created in this transaction is a
            // first-time member, so the room head (including the room.created
            // event) is their common read watermark. Without it each initial
            // member would start with one unread event, and the retention
            // floor would be pinned at zero.
            try await v2InitializeNewRoomReadWatermarks(
                roomID: createdRoomID, now: now, sql: sql
            )

            try await sql.raw("""
                INSERT INTO im_v2.room_events
                    (event_id, room_id, room_sequence, event_type, actor_user_id, payload,
                     committed_membership_revision, created_at)
                VALUES (\(bind: createdEventID), \(bind: createdRoomID), 1, 'room.created', \(bind: input.actorID),
                        jsonb_build_object('event_type', 'room.created', 'room_id', \(bind: createdRoomID.uuidString),
                                           'owner_user_id', \(bind: input.actorID.uuidString), 'title', \(bind: input.title),
                                           'capacity_class', \(bind: input.capacityClass.rawValue),
                                           'membership_revision', 1,
                                           'created_at_ms', \(bind: createdAtMilliseconds)),
                        1, \(bind: now))
                """).run()
            // 会话发现属于每个初始成员的个人状态，不再借用公共消息扇出计划。
            // 直接从本事务的成员关系集合写入，十万成员不进入 Swift 数组。
            try await sql.raw("""
                INSERT INTO im_v2.user_state_event_outbox
                    (source_event_id, user_id, projection_kind, payload, created_at, next_attempt_at, source_room_id)
                SELECT event.event_id, member.user_id, 'room', event.payload, event.created_at, event.created_at, event.room_id
                FROM im_v2.room_events AS event
                JOIN im_v2.room_memberships AS member ON member.room_id = event.room_id
                WHERE event.event_id = \(bind: createdEventID) AND member.left_revision IS NULL
                """).run()

            // Reserve after the private bulk rows are prepared. Rejection
            // still rolls the transaction back, while the shared shard row is
            // not locked throughout the potentially large set-based inserts.
            guard let lease = try await sql.raw("""
                SELECT lease_id, generation, valid_until, command_window_limit,
                       command_window_used
                FROM im_v2.shard_admission_pools
                WHERE room_shard_id = \(bind: roomShardID)
                  AND capacity_profile_id = \(bind: capacityProfile.id)
                FOR UPDATE
                """).first(decoding: GroupShardLeaseRow.self) else {
                return .unavailable
            }
            let initialAdmission = try RoomAdmissionState(
                eligibleMemberCount: input.memberCount,
                commandWindow: .init(limit: capacityProfile.limits.maxCommandsPerWindow))
            let reservation = try V2CommandAdmissionEvaluator.reserve(
                profile: capacityProfile.limits,
                roomState: initialAdmission,
                shardState: try lease.state(),
                now: now
            )
            let reservedRoom: RoomAdmissionState
            let reservedShard: ShardAdmissionState
            switch reservation {
            case .accepted(_, let roomState, let shardState):
                reservedRoom = roomState
                reservedShard = shardState
            case .rateLimited(let seconds):
                return .rateLimited(retryAfterSeconds: seconds)
            case .unavailable:
                return .unavailable
            }
            guard let reservedLease = reservedShard.lease else {
                throw V2GroupMessagingStoreError.corruptPersistenceState
            }
            try await sql.raw("""
                INSERT INTO im_v2.room_admission
                    (room_id, eligible_member_count, command_window_limit, shard_lease_id, shard_lease_generation)
                VALUES (\(bind: createdRoomID), \(bind: input.memberCount), \(bind: capacityProfile.limits.maxCommandsPerWindow), \(bind: try groupUUID(reservedLease.id)), \(bind: try groupSigned(reservedLease.generation)))
                """).run()
            try await sql.raw("""
                UPDATE im_v2.room_admission
                SET command_window_used = \(bind: reservedRoom.commandWindow.used)
                WHERE room_id = \(bind: createdRoomID)
                """).run()
            try await sql.raw("""
                UPDATE im_v2.shard_admission_pools
                SET command_window_used = \(bind: reservedLease.commandWindow.used)
                WHERE room_shard_id = \(bind: roomShardID)
                  AND capacity_profile_id = \(bind: capacityProfile.id)
                  AND lease_id = \(bind: try groupUUID(reservedLease.id))
                  AND generation = \(bind: try groupSigned(reservedLease.generation))
                """).run()

            switch input.audience {
            case .inline(let requestedMembers, _):
                let encoded = try groupUUIDJSON(requestedMembers)
                try await sql.raw("""
                    INSERT INTO im_v2.group_room_operations
                        (actor_user_id, operation_id, room_id, title, capacity_class,
                         audience_kind, initial_member_count, initial_member_user_ids, created_at)
                    VALUES (\(bind: input.actorID), \(bind: input.operationID), \(bind: createdRoomID),
                            \(bind: input.title), \(bind: input.capacityClass.rawValue), 'inline',
                            \(bind: input.memberCount),
                            ARRAY(SELECT value::uuid
                                  FROM jsonb_array_elements_text(\(bind: encoded)::jsonb) AS value
                                  ORDER BY value::uuid),
                            \(bind: now))
                    """).run()
            case .staged, .stagedControlManifest:
                try await sql.raw("""
                    INSERT INTO im_v2.group_room_operations
                        (actor_user_id, operation_id, room_id, title, capacity_class,
                         audience_kind, initial_member_count, initial_member_user_ids, created_at)
                    VALUES (\(bind: input.actorID), \(bind: input.operationID), \(bind: createdRoomID),
                            \(bind: input.title), \(bind: input.capacityClass.rawValue), 'staged',
                            \(bind: input.memberCount), ARRAY[]::uuid[], \(bind: now))
                    """).run()
            }
            if case .stagedControlManifest = input.audience {
                try await sql.raw("""
                    UPDATE im_v2.group_room_creation_intents
                    SET state = 'committed', updated_at = \(bind: now)
                    WHERE actor_user_id = \(bind: input.actorID)
                      AND operation_id = \(bind: input.operationID)
                    """).run()
            }
            return .created(try input.group(roomID: roomID, createdAt: timestamp.createdAt))
        }
    }
}

public enum V2GroupMessagingStoreError: Error, Equatable, Sendable {
    case corruptPersistenceState
}

private struct GroupCommittedTimestampRow: Decodable {
    let createdAt: Date
    enum CodingKeys: String, CodingKey { case createdAt = "created_at" }
}

private enum GroupCreationAudience: Sendable {
    case inline(requestedMembers: [UUID], materializedMembers: [UserID])
    case staged
    case stagedControlManifest

    var kind: String {
        switch self {
        case .inline: "inline"
        case .staged, .stagedControlManifest: "staged"
        }
    }
}

private enum GroupCreationIdentityValidation: Sendable {
    case ownerDatabase
    case controlDatabaseManifest
}

private struct GroupCreationInput: Sendable {
    let actorUserID: UserID
    let actorID: UUID
    let operationID: UUID
    let title: String
    let capacityClass: V2GroupCapacityClass
    let memberCount: Int
    let audience: GroupCreationAudience

    func group(roomID: RoomID, createdAt: Date) throws -> V2GroupRoom {
        let materializedMembers: [UserID]
        switch audience {
        case .inline(_, let members): materializedMembers = members
        case .staged, .stagedControlManifest:
            materializedMembers = [actorUserID]
        }
        return try .init(
            roomID: roomID,
            ownerUserID: actorUserID,
            title: title,
            capacityClass: capacityClass,
            memberUserIDs: materializedMembers,
            memberCount: memberCount,
            createdAt: createdAt
        )
    }
}

private struct GroupShardLeaseRow: Decodable {
    let leaseID: UUID
    let generation: Int64
    let validUntil: Date
    let commandWindowLimit: Int
    let commandWindowUsed: Int

    enum CodingKeys: String, CodingKey {
        case leaseID = "lease_id"
        case generation
        case validUntil = "valid_until"
        case commandWindowLimit = "command_window_limit"
        case commandWindowUsed = "command_window_used"

    }

    func state() throws -> ShardAdmissionState {
        try .init(
            lease: .init(
                id: .init(leaseID.uuidString),
                generation: try groupUnsigned(generation),
                validUntil: validUntil,
                commandWindow: .init(limit: commandWindowLimit, used: commandWindowUsed)))
    }
}

private struct GroupCountRow: Decodable { let value: Int64 }

private struct GroupOwnerIntentValues {
    let actorUserID: UUID
    let operationID: UUID
    let roomID: UUID
    let eventID: UUID

    init(_ intent: V2GroupRoomCreationIntent) throws {
        guard let actorUserID = intent.actorUserID.uuidValue,
              let operationID = intent.operationID.uuidValue,
              let roomID = intent.roomID.uuidValue,
              let eventID = intent.eventID.uuidValue
        else { throw V2GroupMessagingStoreError.corruptPersistenceState }
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.roomID = roomID
        self.eventID = eventID
    }
}

private struct GroupOwnerIntentRow: Decodable {
    let roomID: UUID
    let eventID: UUID
    let roomShardID: String
    let routeEpoch: Int64
    let requestFingerprint: Data
    let audienceMemberCount: Int

    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case eventID = "event_id"
        case roomShardID = "room_shard_id"
        case routeEpoch = "route_epoch"
        case requestFingerprint = "request_fingerprint"
        case audienceMemberCount = "audience_member_count"
    }

    func matches(_ intent: V2GroupRoomCreationIntent) -> Bool {
        roomID == intent.roomID.uuidValue
            && eventID == intent.eventID.uuidValue
            && roomShardID == intent.roomShardID
            && routeEpoch == intent.routeEpoch
            && requestFingerprint == intent.requestFingerprint
            && audienceMemberCount == intent.audienceMemberCount
    }
}

private struct GroupOwnerIntentPageRow: Decodable {
    let memberCount: Int
    let pageDigest: Data
    let isFinal: Bool
    enum CodingKeys: String, CodingKey {
        case memberCount = "member_count"
        case pageDigest = "page_digest"
        case isFinal = "is_final"
    }
}

private struct GroupOwnerManifestSummaryRow: Decodable {
    let pageCount: Int64
    let minimumPage: Int64
    let maximumPage: Int64
    let declaredMembers: Int64
    let finalCount: Int64
    let finalPage: Int64
    let materializedMembers: Int64
    enum CodingKeys: String, CodingKey {
        case pageCount = "page_count"
        case minimumPage = "minimum_page"
        case maximumPage = "maximum_page"
        case declaredMembers = "declared_members"
        case finalCount = "final_count"
        case finalPage = "final_page"
        case materializedMembers = "materialized_members"
    }
}

private struct GroupStagedDraftRow: Decodable {
    let title: String
    let state: String
    let memberCount: Int64
    enum CodingKeys: String, CodingKey {
        case title, state
        case memberCount = "member_count"
    }
}

private struct GroupOperationRow: Decodable {
    let roomID: UUID
    let title: String
    let capacityClass: V2GroupCapacityClass
    let audienceKind: String
    let initialMemberCount: Int
    let initialMemberUserIDs: [UUID]
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case title
        case capacityClass = "capacity_class"
        case audienceKind = "audience_kind"
        case initialMemberCount = "initial_member_count"
        case initialMemberUserIDs = "initial_member_user_ids"
        case createdAt = "created_at"
    }

    func matches(_ input: GroupCreationInput) -> Bool {
        guard title == input.title,
              capacityClass == input.capacityClass,
              audienceKind == input.audience.kind,
              initialMemberCount == input.memberCount
        else { return false }
        switch input.audience {
        case .inline(let requestedMembers, _):
            return initialMemberUserIDs == requestedMembers.sorted()
        case .staged, .stagedControlManifest:
            return initialMemberUserIDs.isEmpty
        }
    }

    func group(ownerUserID: UserID) throws -> V2GroupRoom {
        guard initialMemberCount > 0, v2PostgresTimestampCanEncode(createdAt) else {
            throw V2GroupMessagingStoreError.corruptPersistenceState
        }
        let materializedMembers: [UserID]
        switch audienceKind {
        case "inline":
            materializedMembers = [ownerUserID] + (try initialMemberUserIDs.map { try UserID($0.uuidString) })
        case "staged":
            guard initialMemberUserIDs.isEmpty else {
                throw V2GroupMessagingStoreError.corruptPersistenceState
            }
            materializedMembers = [ownerUserID]
        default:
            throw V2GroupMessagingStoreError.corruptPersistenceState
        }
        return try .init(
            roomID: try .init(roomID.uuidString),
            ownerUserID: ownerUserID,
            title: title,
            capacityClass: capacityClass,
            memberUserIDs: materializedMembers,
            memberCount: initialMemberCount,
            createdAt: createdAt
        )
    }
}

private func groupUUID<Tag>(_ identifier: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag {
    guard let value = UUID(uuidString: identifier.rawValue) else {
        throw V2GroupMessagingStoreError.corruptPersistenceState
    }
    return value
}

private func groupUUIDJSON(_ values: [UUID]) throws -> String {
    guard let encoded = String(
        data: try JSONEncoder().encode(values.map(\.uuidString)),
        encoding: .utf8
    ) else { throw V2GroupMessagingStoreError.corruptPersistenceState }
    return encoded
}

private func groupUnsigned(_ value: Int64) throws -> UInt64 {
    guard value >= 0 else { throw V2GroupMessagingStoreError.corruptPersistenceState }
    return UInt64(value)
}

private func groupSigned(_ value: UInt64) throws -> Int64 {
    guard value <= UInt64(Int64.max) else { throw V2GroupMessagingStoreError.corruptPersistenceState }
    return Int64(value)
}
