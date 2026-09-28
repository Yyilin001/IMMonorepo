import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// PostgreSQL 群引导事务。
///
/// 它在同一事务内创建房间、初始成员关系、准入状态、个人会话发现待办与操作台账。
/// 分阶段受众在整个事务中始终保持关系形态，因此十万成员群不会变成 Swift 数组
/// 或一个巨大的 PostgreSQL 参数数组。
public struct PostgresV2GroupMessagingStore: Sendable {
    private let database: any Database

    /// 组合数据库；新群统一使用房间日志。
    ///
    /// - Parameters:
    ///   - database: 存放房间、事件与投递的数据库。
    public init(database: any Database) {
        self.database = database
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
            if let row = try await sql.raw("SELECT receipt::text AS receipt FROM im_v2.group_creation_owner_receipts WHERE actor_user_id = \(bind: values.actorUserID) AND operation_id = \(bind: values.operationID)").first(decoding: ProvenGroupReceiptRow.self) {
                let receipt = try JSONDecoder().decode(V2GroupCreationReceipt.self, from: Data(row.receipt.utf8))
                guard receipt.identity.accountID == intent.actorUserID,
                      receipt.identity.operation.rawOperationID == intent.operationID.rawValue,
                      receipt.fingerprint.digest == intent.requestFingerprint,
                      case .created(let room,_,_,_) = receipt.outcome, room == intent.roomID else { throw V2GroupRoomCreationIntentStoreError.routeConflict }
                return
            }

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

    public func createProvenGroup(intent: V2GroupCreationIntent, placement: V2GroupRoomCreationIntent,
                                  capacityProfile: V2CapacityProfile, now: Date) async throws -> V2GroupCreationOperationResult {
        guard intent.identity.accountID == placement.actorUserID,
              intent.identity.operation.rawOperationID == placement.operationID.rawValue,
              placement.requestFingerprint == (try intent.fingerprint.digest),
              placement.audienceMemberCount == intent.initialMemberCount + 1 else {
            throw V2GroupMessagingStoreError.corruptPersistenceState
        }
        let result = try await createGroup(input: .init(actorUserID: placement.actorUserID,
            actorID: try groupUUID(placement.actorUserID), operationID: try groupUUID(placement.operationID),
            title: intent.title, capacityClass: intent.capacityClass, memberCount: placement.audienceMemberCount),
            capacityProfile: capacityProfile, roomShardID: placement.roomShardID,
            roomID: placement.roomID, eventID: placement.eventID, now: now, creationIntent: intent)
        switch result {
        case .created, .idempotent:
            guard let sql = database as? any SQLDatabase,
                  let row = try await sql.raw("SELECT receipt::text AS receipt FROM im_v2.group_creation_owner_receipts WHERE actor_user_id = \(bind: try groupUUID(placement.actorUserID)) AND operation_id = \(bind: try groupUUID(placement.operationID))").first(decoding: ProvenGroupReceiptRow.self) else { throw V2GroupMessagingStoreError.corruptPersistenceState }
            let receipt = try JSONDecoder().decode(V2GroupCreationReceipt.self, from: Data(row.receipt.utf8))
            guard receipt.validates(intent: intent) else { throw V2GroupMessagingStoreError.corruptPersistenceState }
            return .receipt(receipt)
        case .idempotencyConflict: return .fingerprintConflict
        case .rateLimited(let seconds): return .deferred(try .init(identity: intent.identity, fingerprint: intent.fingerprint, reason: .rateLimited, retryAfterMilliseconds: UInt64(max(1,seconds)) * 1_000))
        default: return .deferred(try .init(identity: intent.identity, fingerprint: intent.fingerprint, reason: .admissionUnavailable, retryAfterMilliseconds: nil))
        }
    }

    private func createGroup(
        input: GroupCreationInput,
        capacityProfile: V2CapacityProfile,
        roomShardID: String,
        roomID: RoomID,
        eventID: EventID,
        now: Date,
        creationIntent: V2GroupCreationIntent
    ) async throws -> V2CreateGroupRoomOutcome {
        do { return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2GroupMessagingStoreError.corruptPersistenceState
            }
            let operationLockKey = input.actorID.uuidString + ":" + input.operationID.uuidString
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: operationLockKey), 0))").run()

            do {
                if let row = try await sql.raw("SELECT receipt::text AS receipt FROM im_v2.group_creation_owner_receipts WHERE actor_user_id = \(bind: input.actorID) AND operation_id = \(bind: input.operationID)").first(decoding: ProvenGroupReceiptRow.self) {
                    let receipt = try JSONDecoder().decode(V2GroupCreationReceipt.self, from: Data(row.receipt.utf8))
                    guard receipt.validates(intent: creationIntent), case .created(let originalRoom,_,_,_) = receipt.outcome, originalRoom == roomID else { return .idempotencyConflict }
                    return .idempotent(try input.group(roomID: originalRoom, createdAt: Date(timeIntervalSince1970: Double(receipt.resolvedAtMilliseconds)/1_000)))
                }
                guard input.memberCount <= capacityProfile.limits.maxEligibleMembers else { return .memberLimitReached }
                let rows = try await sql.raw("SELECT user_id FROM im_v2.group_room_creation_intent_members WHERE actor_user_id = \(bind: input.actorID) AND operation_id = \(bind: input.operationID) ORDER BY user_id LIMIT 100001").all(decoding: ProvenGroupMemberRow.self)
                let others = rows.map { UserID(uuid: $0.userID) }.filter { $0 != creationIntent.identity.accountID }
                guard rows.count == creationIntent.initialMemberCount + 1,
                      rows.contains(where: { $0.userID == input.actorID }),
                      creationIntent.audienceDigest == (try V2GroupCreationAudience.digest(others)) else { return .idempotencyConflict }
            }

            guard v2PostgresTimestampCanEncode(now) else {
                throw V2GroupMessagingStoreError.corruptPersistenceState
            }
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

            let createdRoomID = try groupUUID(roomID)
            let createdEventID = try groupUUID(eventID)
            // 响应和投影使用持久化后的时间精度；其他写入保留原始 Date。
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

                try await sql.raw("""
                    INSERT INTO im_v2.room_memberships
                        (room_id, user_id, role, joined_revision)
                    SELECT \(bind: createdRoomID), member.user_id, 'member', 1
                    FROM im_v2.group_room_creation_intent_members AS member
                    WHERE member.actor_user_id = \(bind: input.actorID)
                      AND member.operation_id = \(bind: input.operationID)
                    AND member.user_id <> \(bind: input.actorID)
                    """).run()

            // 此事务创建的房间中，每位活跃成员都是首次加入；
            // 因此包含 room.created 事件的房间日志头，是他们共同的已读水位。
            // 若不设置，初始成员各自都会有一条未读事件，
            // 保留下界也会被固定在零。
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

            // 准备好私有批量记录后再预留。拒绝仍会回滚整个事务；
            // 共享分片记录不会在可能很大的集合式插入期间一直被锁定。
            guard let lease = try await sql.raw("""
                SELECT lease_id, generation, valid_until, command_window_limit,
                       command_window_used
                FROM im_v2.shard_admission_pools
                WHERE room_shard_id = \(bind: roomShardID)
                  AND capacity_profile_id = \(bind: capacityProfile.id)
                FOR UPDATE
                """).first(decoding: GroupShardLeaseRow.self) else {
                throw ProvenGroupDeferred.unavailable
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
                throw ProvenGroupDeferred.rateLimited(seconds)
            case .unavailable:
                throw ProvenGroupDeferred.unavailable
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

                guard let resolvedMilliseconds=UInt64(exactly:createdAtMilliseconds) else { throw V2GroupMessagingStoreError.corruptPersistenceState }
                let receipt = try V2GroupCreationReceipt(intent: creationIntent,
                    outcome: .created(roomID: roomID, title: input.title, capacityClass: input.capacityClass, memberCount: input.memberCount),
                    resolvedAtMilliseconds: resolvedMilliseconds)
                guard let encoded = String(data: try JSONEncoder().encode(receipt), encoding: .utf8) else { throw V2GroupMessagingStoreError.corruptPersistenceState }
                try await sql.raw("INSERT INTO im_v2.group_creation_owner_receipts(actor_user_id,operation_id,room_id,receipt) VALUES (\(bind: input.actorID),\(bind: input.operationID),\(bind: createdRoomID),\(bind: encoded)::jsonb)").run()
            do {
                try await sql.raw("""
                    UPDATE im_v2.group_room_creation_intents
                    SET state = 'committed', updated_at = \(bind: now)
                    WHERE actor_user_id = \(bind: input.actorID)
                      AND operation_id = \(bind: input.operationID)
                    """).run()
            }
            // The permanent proof replaces the large bootstrap audience. A late
            // duplicate stage observes that proof and cannot recreate this payload.
            try await sql.raw("DELETE FROM im_v2.group_room_creation_intent_members WHERE actor_user_id = \(bind: input.actorID) AND operation_id = \(bind: input.operationID)").run()
            try await sql.raw("DELETE FROM im_v2.group_room_creation_intent_pages WHERE actor_user_id = \(bind: input.actorID) AND operation_id = \(bind: input.operationID)").run()
            return .created(try input.group(roomID: roomID, createdAt: timestamp.createdAt))
        }
        } catch ProvenGroupDeferred.rateLimited(let seconds) { return .rateLimited(retryAfterSeconds: seconds) }
          catch ProvenGroupDeferred.unavailable { return .unavailable }
    }
}

private enum ProvenGroupDeferred: Error { case rateLimited(Int), unavailable }
private struct ProvenGroupReceiptRow: Decodable { let receipt: String }
private struct ProvenGroupMemberRow: Decodable { let userID: UUID; enum CodingKeys: String, CodingKey { case userID = "user_id" } }

public enum V2GroupMessagingStoreError: Error, Equatable, Sendable {
    case corruptPersistenceState
}

private struct GroupCommittedTimestampRow: Decodable {
    let createdAt: Date
    enum CodingKeys: String, CodingKey { case createdAt = "created_at" }
}

private struct GroupCreationInput: Sendable {
    let actorUserID: UserID
    let actorID: UUID
    let operationID: UUID
    let title: String
    let capacityClass: V2GroupCapacityClass
    let memberCount: Int

    func group(roomID: RoomID, createdAt: Date) throws -> V2GroupRoom {
        return try .init(
            roomID: roomID,
            ownerUserID: actorUserID,
            title: title,
            capacityClass: capacityClass,
            memberUserIDs: [actorUserID],
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
