import Foundation
import IMV2Core
import NIOCore
import PostgresNIO
import SQLKit

// 借用 Store 的事务连接；排序、加锁与授权都在该连接上完成。
// 事务与最终预留由 Store 负责。
enum PlainHybridGroupPreflight {
    /// 普通混合群组发送的集合式权威预检。
    ///
    /// 房间/准入/成员的加锁顺序与标量路径完全一致。
    /// 权限判定基于同一批持久策略行求值，而房间锁则为并发的策略变更建立围栏。
    ///
    /// - Parameters:
    ///   - ordered: 已排序的房间写入请求。
    ///   - sql: 参与当前事务的数据库连接。
    /// - Returns: 各请求对应的预检结果行。
    /// - Throws: 预检不匹配或查询失败时抛出。
    static func load(
        _ ordered: [OrderedRoomWriteRequest],
        sql: any SQLDatabase
    ) async throws -> [PlainHybridGroupBatchPreflightRow] {
        let input = try ordered.map { item in
            PlainHybridGroupBatchPreflightInput(
                ordinal: item.preflightOrdinal,
                roomID: item.roomID,
                senderID: item.senderID,
                clientMessageID: try hybridPreflightUUID(item.request.command.clientMessageID),
                nowPostgresMicroseconds: try roomWritePostgresMicroseconds(item.request.now)
            )
        }
        // 生产环境使用有类型列数组的命名语句。
        // 下方的授权关系与加锁顺序不变；此处只省去逐批 JSON 编解码，
        // 并让每条前台物理连接复用 PostgreSQL 预处理计划。
        if let postgres = sql as? any PostgresDatabase {
            let statement = try PlainHybridGroupBatchPreflightStatement(inputs: input)
            let rows = try await postgres.withConnection { connection in
                connection.eventLoop.makeFutureWithTask {
                    let result = try await connection.execute(
                        statement,
                        logger: connection.logger
                    )
                    var decoded: [PlainHybridGroupBatchPreflightRow] = []
                    decoded.reserveCapacity(input.count)
                    for try await row in result {
                        decoded.append(row)
                    }
                    return decoded
                }
            }.get()
            guard rows.count == ordered.count,
                  zip(rows, ordered).allSatisfy({
                      $0.0.ordinal == $0.1.preflightOrdinal
                  })
            else { throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch) }
            return rows
        }
        let inputJSON = try roomWriteJSON(input)
        let rows = try await sql.raw("""
            WITH input AS MATERIALIZED (
                SELECT input.ordinal, input.room_id, input.sender_id,
                       input.client_message_id, input.now_postgres_microseconds
                FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb) AS input(
                    ordinal integer,
                    room_id uuid,
                    sender_id uuid,
                    client_message_id uuid,
                    now_postgres_microseconds bigint
                )
            ), locked_room AS MATERIALIZED (
                SELECT input.ordinal, input.sender_id, input.client_message_id,
                       input.now_postgres_microseconds, room.room_kind,
                       room.room_shard_id, room.room_sequence,
                       room.timeline_sequence, room.membership_revision,
                       room.capacity_profile_id, room.capacity_class,
                       room.frozen_at, room.room_id
                FROM input
                JOIN im_v2.rooms AS room ON room.room_id = input.room_id
                ORDER BY room.room_id
                FOR UPDATE OF room
            ), prior_operation AS MATERIALIZED (
                SELECT room.ordinal
                FROM locked_room AS room
                JOIN im_v2.message_send_completions AS message
                  ON message.sender_user_id = room.sender_id
                  AND message.room_id = room.room_id
                 AND message.client_message_id = room.client_message_id
            ), fresh_room AS MATERIALIZED (
                SELECT room.*
                FROM locked_room AS room
                WHERE NOT EXISTS (
                    SELECT 1 FROM prior_operation AS prior
                    WHERE prior.ordinal = room.ordinal
                )
            ), locked_admission AS MATERIALIZED (
                SELECT room.ordinal,
                       admission.eligible_member_count AS room_eligible_member_count,
                       admission.command_window_limit AS room_command_window_limit,
                       admission.command_window_used AS room_command_window_used,
                       admission.shard_lease_id AS room_shard_lease_id,
                       admission.shard_lease_generation AS room_shard_lease_generation,
                       shard.lease_id AS shard_lease_id,
                       shard.generation AS shard_generation,
                       shard.valid_until AS shard_valid_until,
                       shard.command_window_limit AS shard_command_window_limit,
                       shard.command_window_used AS shard_command_window_used
                FROM fresh_room AS room
                JOIN im_v2.room_admission AS admission
                  ON admission.room_id = room.room_id
                JOIN im_v2.shard_admission_pools AS shard
                  ON shard.room_shard_id = room.room_shard_id
                 AND shard.capacity_profile_id = room.capacity_profile_id
                ORDER BY room.room_id
                FOR UPDATE OF admission
            ), locked_actor AS MATERIALIZED (
                SELECT room.ordinal, membership.role AS actor_role,
                       EXISTS (
                           SELECT 1
                           FROM im_v2.public_user_profiles AS profile
                           WHERE profile.user_id = room.sender_id
                             AND profile.state = 'active'
                             AND NOT EXISTS (
                                 SELECT 1 FROM im_v2.account_disables AS disabled
                                 WHERE disabled.user_id = profile.user_id
                             )
                       ) AS sender_is_active,
                       EXISTS (
                           SELECT 1 FROM im_v2.room_member_mutes AS mute
                           WHERE mute.room_id = room.room_id
                             AND mute.user_id = room.sender_id
                             AND mute.mute_until > ((TIMESTAMP '2000-01-01 00:00:00'
                             + (room.now_postgres_microseconds / 86400000000) * INTERVAL '1 day'
                             + (room.now_postgres_microseconds % 86400000000) * INTERVAL '1 microsecond')
                             AT TIME ZONE 'UTC')
                       ) AS muted,
                       (
                           membership.role = 'owner'
                           OR EXISTS (
                               SELECT 1 FROM im_v2.group_role_permissions AS permission
                               WHERE permission.room_id = room.room_id
                                 AND permission.role = membership.role
                                 AND permission.permission = 'send_messages'
                           )
                           OR NOT EXISTS (
                               SELECT 1 FROM (SELECT room_id, role FROM im_v2.group_role_policies UNION ALL SELECT room_id, role FROM im_v2.group_role_permissions) AS operation
                               WHERE operation.room_id = room.room_id
                                 AND operation.role = membership.role
                           )
                       ) AS allows_send_messages
                FROM fresh_room AS room
                JOIN locked_admission AS admission USING (ordinal)
                JOIN im_v2.room_memberships AS membership
                  ON membership.room_id = room.room_id
                 AND membership.user_id = room.sender_id
                 AND membership.joined_revision <= room.membership_revision
                 AND (membership.left_revision IS NULL
                      OR membership.left_revision > room.membership_revision)
                ORDER BY room.room_id, membership.user_id
                FOR UPDATE OF membership
            )
            SELECT room.ordinal, room.room_kind, room.room_shard_id,
                   room.room_sequence, room.timeline_sequence,
                   room.membership_revision, room.capacity_profile_id,
                   room.capacity_class, room.frozen_at,
                   EXISTS (
                       SELECT 1 FROM prior_operation AS prior
                       WHERE prior.ordinal = room.ordinal
                   ) AS has_prior_operation,
                   admission.room_eligible_member_count,
                   admission.room_command_window_limit,
                   admission.room_command_window_used,
                   admission.room_shard_lease_id,
                   admission.room_shard_lease_generation,
                   admission.shard_lease_id, admission.shard_generation,
                   admission.shard_valid_until,
                   admission.shard_command_window_limit,
                   admission.shard_command_window_used,
                   actor.actor_role, actor.sender_is_active, actor.muted,
                   actor.allows_send_messages
            FROM locked_room AS room
            LEFT JOIN locked_admission AS admission USING (ordinal)
            LEFT JOIN locked_actor AS actor USING (ordinal)
            ORDER BY room.ordinal
            """).all().map { try PlainHybridGroupBatchPreflightRow(row: $0) }
        guard rows.count == ordered.count,
              zip(rows, ordered).allSatisfy({ $0.0.ordinal == $0.1.preflightOrdinal })
        else { throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch) }
        return rows
    }
}

private func hybridPreflightUUID<Tag>(_ value: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag {
    guard let value = value.uuidValue else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return value
}

private struct PlainHybridGroupBatchPreflightInput: Encodable {
    let ordinal: Int
    let roomID: UUID
    let senderID: UUID
    let clientMessageID: UUID
    let nowPostgresMicroseconds: Int64

    enum CodingKeys: String, CodingKey {
        case ordinal
        case roomID = "room_id"
        case senderID = "sender_id"
        case clientMessageID = "client_message_id"
        case nowPostgresMicroseconds = "now_postgres_microseconds"
    }
}

/// 权威混合群组预检的具名、类型化数组形式。
///
/// 该语句刻意返回与 SQLKit 回退实现相同的 36 个持久字段。
/// 任何缓存权限布尔值都不会被接受为权威：
/// PostgreSQL 仍会锁定房间、准入行与发送者成员关系，
/// 并在事务内求值启用/禁言/角色权限状态。
private struct PlainHybridGroupBatchPreflightStatement: PostgresPreparedStatement {
    static let name = "im_v2_plain_hybrid_group_batch_preflight_v3"
    static let sql = """
        WITH input AS MATERIALIZED (
            SELECT (input.ordinality - 1)::integer AS ordinal,
                   input.room_id, input.sender_id,
                   input.client_message_id, input.now_postgres_microseconds
            FROM unnest(
                $1::uuid[], $2::uuid[], $3::uuid[], $4::bigint[]
            ) WITH ORDINALITY AS input(
                room_id, sender_id, client_message_id, now_postgres_microseconds,
                ordinality
            )
        ), locked_room AS MATERIALIZED (
            SELECT input.ordinal, input.sender_id, input.client_message_id,
                   input.now_postgres_microseconds, room.room_kind,
                   room.room_shard_id, room.room_sequence,
                   room.timeline_sequence, room.membership_revision,
                   room.capacity_profile_id, room.capacity_class,
                   room.frozen_at, room.room_id
            FROM input
            JOIN im_v2.rooms AS room ON room.room_id = input.room_id
            ORDER BY room.room_id
            FOR UPDATE OF room
        ), prior_operation AS MATERIALIZED (
            SELECT room.ordinal
            FROM locked_room AS room
            JOIN im_v2.message_send_completions AS message
              ON message.sender_user_id = room.sender_id
                  AND message.room_id = room.room_id
             AND message.client_message_id = room.client_message_id
        ), fresh_room AS MATERIALIZED (
            SELECT room.*
            FROM locked_room AS room
            WHERE NOT EXISTS (
                SELECT 1 FROM prior_operation AS prior
                WHERE prior.ordinal = room.ordinal
            )
        ), locked_admission AS MATERIALIZED (
            SELECT room.ordinal,
                   admission.eligible_member_count AS room_eligible_member_count,
                   admission.command_window_limit AS room_command_window_limit,
                   admission.command_window_used AS room_command_window_used,
                   admission.shard_lease_id AS room_shard_lease_id,
                   admission.shard_lease_generation AS room_shard_lease_generation,
                   shard.lease_id AS shard_lease_id,
                   shard.generation AS shard_generation,
                   shard.valid_until AS shard_valid_until,
                   shard.command_window_limit AS shard_command_window_limit,
                   shard.command_window_used AS shard_command_window_used
            FROM fresh_room AS room
            JOIN im_v2.room_admission AS admission
              ON admission.room_id = room.room_id
            JOIN im_v2.shard_admission_pools AS shard
              ON shard.room_shard_id = room.room_shard_id
             AND shard.capacity_profile_id = room.capacity_profile_id
            ORDER BY room.room_id
            FOR UPDATE OF admission
        ), locked_actor AS MATERIALIZED (
            SELECT room.ordinal, membership.role AS actor_role,
                   EXISTS (
                       SELECT 1
                       FROM im_v2.public_user_profiles AS profile
                       WHERE profile.user_id = room.sender_id
                         AND profile.state = 'active'
                         AND NOT EXISTS (
                             SELECT 1 FROM im_v2.account_disables AS disabled
                             WHERE disabled.user_id = profile.user_id
                         )
                   ) AS sender_is_active,
                   EXISTS (
                       SELECT 1 FROM im_v2.room_member_mutes AS mute
                       WHERE mute.room_id = room.room_id
                         AND mute.user_id = room.sender_id
                         AND mute.mute_until > ((TIMESTAMP '2000-01-01 00:00:00'
                             + (room.now_postgres_microseconds / 86400000000) * INTERVAL '1 day'
                             + (room.now_postgres_microseconds % 86400000000) * INTERVAL '1 microsecond')
                             AT TIME ZONE 'UTC')
                   ) AS muted,
                   (
                       membership.role = 'owner'
                       OR EXISTS (
                           SELECT 1 FROM im_v2.group_role_permissions AS permission
                           WHERE permission.room_id = room.room_id
                             AND permission.role = membership.role
                             AND permission.permission = 'send_messages'
                       )
                       OR NOT EXISTS (
                           SELECT 1 FROM (SELECT room_id, role FROM im_v2.group_role_policies UNION ALL SELECT room_id, role FROM im_v2.group_role_permissions) AS operation
                           WHERE operation.room_id = room.room_id
                             AND operation.role = membership.role
                       )
                   ) AS allows_send_messages
            FROM fresh_room AS room
            JOIN locked_admission AS admission USING (ordinal)
            JOIN im_v2.room_memberships AS membership
              ON membership.room_id = room.room_id
             AND membership.user_id = room.sender_id
             AND membership.joined_revision <= room.membership_revision
             AND (membership.left_revision IS NULL
                  OR membership.left_revision > room.membership_revision)
            ORDER BY room.room_id, membership.user_id
            FOR UPDATE OF membership
        )
        SELECT room.ordinal, room.room_kind, room.room_shard_id,
               room.room_sequence, room.timeline_sequence,
               room.membership_revision, room.capacity_profile_id,
               room.capacity_class, room.frozen_at,
               EXISTS (
                   SELECT 1 FROM prior_operation AS prior
                   WHERE prior.ordinal = room.ordinal
               ) AS has_prior_operation,
               admission.room_eligible_member_count,
               admission.room_command_window_limit,
               admission.room_command_window_used,
               admission.room_shard_lease_id,
               admission.room_shard_lease_generation,
               admission.shard_lease_id, admission.shard_generation,
               admission.shard_valid_until,
               admission.shard_command_window_limit,
               admission.shard_command_window_used,
               actor.actor_role, actor.sender_is_active, actor.muted,
               actor.allows_send_messages
        FROM locked_room AS room
        LEFT JOIN locked_admission AS admission USING (ordinal)
        LEFT JOIN locked_actor AS actor USING (ordinal)
        ORDER BY room.ordinal
        """

    typealias Row = PlainHybridGroupBatchPreflightRow

    let inputs: [PlainHybridGroupBatchPreflightInput]

    init(inputs: [PlainHybridGroupBatchPreflightInput]) throws {
        guard inputs.enumerated().allSatisfy({ $0.offset == $0.element.ordinal })
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        self.inputs = inputs
    }

    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 4)
        bindings.append(inputs.map(\.roomID))
        bindings.append(inputs.map(\.senderID))
        bindings.append(inputs.map(\.clientMessageID))
        bindings.append(inputs.map(\.nowPostgresMicroseconds))
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> Row {
        try .init(postgresRow: row)
    }
}

/// 顺序解码。
///
/// 其复杂度为 O(列数)，既不需要分配键控 Codable 容器，
/// 也无需为每个返回行执行 36 次字符串查找。
private struct PlainHybridGroupPreparedRowCursor {
    private var iterator: PostgresRow.Iterator

    init(_ row: PostgresRow) {
        iterator = row.makeIterator()
    }

    mutating func decode<T: PostgresDecodable>(_ type: T.Type = T.self) throws -> T {
        guard let cell = iterator.next() else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        return try cell.decode(type)
    }

    mutating func assertExhausted() throws {
        guard iterator.next() == nil else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
    }
}

struct PlainHybridGroupBatchPreflightRow: Decodable {
    let ordinal: Int
    let kind: String
    let roomShardID: String
    let roomSequence: Int64
    let timelineSequence: Int64
    let membershipRevision: Int64
    let capacityProfileID: String
    let capacityClass: V2GroupCapacityClass
    let frozenAt: Date?
    let hasPriorOperation: Bool
    let roomEligibleMemberCount: Int?
    let roomCommandWindowLimit: Int?
    let roomCommandWindowUsed: Int?
                            let roomShardLeaseID: UUID?
    let roomShardLeaseGeneration: Int64?
    let shardLeaseID: UUID?
    let shardGeneration: Int64?
    let shardValidUntil: Date?
    let shardCommandWindowLimit: Int?
    let shardCommandWindowUsed: Int?
                            let actorRole: String?
    let senderIsActive: Bool?
    let muted: Bool?
    let allowsSendMessages: Bool?

    init(postgresRow: PostgresRow) throws {
        var row = PlainHybridGroupPreparedRowCursor(postgresRow)
        ordinal = try row.decode()
        kind = try row.decode()
        roomShardID = try row.decode()
        roomSequence = try row.decode()
        timelineSequence = try row.decode()
        membershipRevision = try row.decode()
        capacityProfileID = try row.decode()
        let capacityClassValue: String = try row.decode()
        guard let capacityClass = V2GroupCapacityClass(rawValue: capacityClassValue) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        self.capacityClass = capacityClass
        frozenAt = try row.decode()
        hasPriorOperation = try row.decode()
        roomEligibleMemberCount = try row.decode()
        roomCommandWindowLimit = try row.decode()
        roomCommandWindowUsed = try row.decode()

        roomShardLeaseID = try row.decode()
        roomShardLeaseGeneration = try row.decode()
        shardLeaseID = try row.decode()
        shardGeneration = try row.decode()
        shardValidUntil = try row.decode()
        shardCommandWindowLimit = try row.decode()
        shardCommandWindowUsed = try row.decode()

        actorRole = try row.decode()
        senderIsActive = try row.decode()
        muted = try row.decode()
        allowsSendMessages = try row.decode()
        try row.assertExhausted()
    }

    /// 这是混合群组准入中最热的行。直接按列解码，
    /// 而不是为每条消息都构造一个通用的键控 Codable 容器。
    /// PostgreSQL 的类型校验与所有授权字段都保持不变，只有 Swift 的解码机制不同。
    ///
    /// - Parameter row: 待解码的数据库行。
    /// - Throws: 类型校验失败或列缺失时抛出。
    init(row: any SQLRow) throws {
        ordinal = try row.decode(column: "ordinal")
        kind = try row.decode(column: "room_kind")
        roomShardID = try row.decode(column: "room_shard_id")
        roomSequence = try row.decode(column: "room_sequence")
        timelineSequence = try row.decode(column: "timeline_sequence")
        membershipRevision = try row.decode(column: "membership_revision")
        capacityProfileID = try row.decode(column: "capacity_profile_id")
        capacityClass = try row.decode(column: "capacity_class")
        frozenAt = try row.decode(column: "frozen_at", as: Date?.self)
        hasPriorOperation = try row.decode(column: "has_prior_operation")
        roomEligibleMemberCount = try row.decode(
            column: "room_eligible_member_count",
            as: Int?.self
        )
        roomCommandWindowLimit = try row.decode(column: "room_command_window_limit", as: Int?.self)
        roomCommandWindowUsed = try row.decode(column: "room_command_window_used", as: Int?.self)

        roomShardLeaseID = try row.decode(column: "room_shard_lease_id", as: UUID?.self)
        roomShardLeaseGeneration = try row.decode(
            column: "room_shard_lease_generation",
            as: Int64?.self
        )
        shardLeaseID = try row.decode(column: "shard_lease_id", as: UUID?.self)
        shardGeneration = try row.decode(column: "shard_generation", as: Int64?.self)
        shardValidUntil = try row.decode(column: "shard_valid_until", as: Date?.self)
        shardCommandWindowLimit = try row.decode(column: "shard_command_window_limit", as: Int?.self)
        shardCommandWindowUsed = try row.decode(column: "shard_command_window_used", as: Int?.self)

        actorRole = try row.decode(column: "actor_role", as: String?.self)
        senderIsActive = try row.decode(column: "sender_is_active", as: Bool?.self)
        muted = try row.decode(column: "muted", as: Bool?.self)
        allowsSendMessages = try row.decode(column: "allows_send_messages", as: Bool?.self)
    }

    enum CodingKeys: String, CodingKey {
        case ordinal
        case kind = "room_kind"
        case roomShardID = "room_shard_id"
        case roomSequence = "room_sequence"
        case timelineSequence = "timeline_sequence"
        case membershipRevision = "membership_revision"
        case capacityProfileID = "capacity_profile_id"
        case capacityClass = "capacity_class"
        case frozenAt = "frozen_at"
        case hasPriorOperation = "has_prior_operation"
        case roomEligibleMemberCount = "room_eligible_member_count"
        case roomCommandWindowLimit = "room_command_window_limit"
        case roomCommandWindowUsed = "room_command_window_used"

        case roomShardLeaseID = "room_shard_lease_id"
        case roomShardLeaseGeneration = "room_shard_lease_generation"
        case shardLeaseID = "shard_lease_id"
        case shardGeneration = "shard_generation"
        case shardValidUntil = "shard_valid_until"
        case shardCommandWindowLimit = "shard_command_window_limit"
        case shardCommandWindowUsed = "shard_command_window_used"

        case actorRole = "actor_role"
        case senderIsActive = "sender_is_active"
        case muted
        case allowsSendMessages = "allows_send_messages"
    }

    var room: RoomRow {
        .init(
            kind: kind,
            roomShardID: roomShardID,
            roomSequence: roomSequence,
            timelineSequence: timelineSequence,
            membershipRevision: membershipRevision,
            capacityProfileID: capacityProfileID,
            capacityClass: capacityClass,

            frozenAt: frozenAt
        )
    }

    func admissionSnapshot() throws -> AdmissionSnapshotRow {
        guard let roomEligibleMemberCount, let roomCommandWindowLimit,
              let roomCommandWindowUsed, let roomShardLeaseID,
              let roomShardLeaseGeneration, let shardLeaseID,
              let shardGeneration, let shardValidUntil,
              let shardCommandWindowLimit, let shardCommandWindowUsed
        else { throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch) }
        return .init(
            roomEligibleMemberCount: roomEligibleMemberCount,
            roomCommandWindowLimit: roomCommandWindowLimit,
            roomCommandWindowUsed: roomCommandWindowUsed,

            roomShardLeaseID: roomShardLeaseID,
            roomShardLeaseGeneration: roomShardLeaseGeneration,
            shardLeaseID: shardLeaseID,
            shardGeneration: shardGeneration,
            shardValidUntil: shardValidUntil,
            shardCommandWindowLimit: shardCommandWindowLimit,
            shardCommandWindowUsed: shardCommandWindowUsed,

            actorRole: actorRole,
            senderIsActive: senderIsActive,
            muted: muted
        )
    }
}
