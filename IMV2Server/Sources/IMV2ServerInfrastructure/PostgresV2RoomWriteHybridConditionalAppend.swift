import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core
import NIOCore
import PostgresNIO
import SQLKit

// 在 Store 借用的事务连接上执行。不负责所有者围栏、不匹配诊断、
// 额度结算或事务提交。
enum PlainHybridGroupConditionalWritePath {
    static func execute(
        _ ordered: [OrderedRoomWriteRequest],
        acquisitions: [V2ShardAdmissionCommandCreditPool.Acquisition],
        snapshotsByRoomID: [UUID: V2HybridGroupShardCreditSnapshotCache.Entry],
        sql: any SQLDatabase
    ) async throws -> [PlainHybridGroupConditionalAllocationRow] {
        guard let postgres = sql as? any PostgresDatabase,
              ordered.count == acquisitions.count,
              !ordered.isEmpty
        else { throw V2RoomWriteStoreError.corruptPersistenceState }

        let inputs = try zip(ordered, acquisitions).map { item, acquisition in
            guard case .granted(_, let effectiveShardState) = acquisition,
                  let lease = effectiveShardState.lease,
                  let leaseID = UUID(uuidString: lease.id.rawValue),
                  let generation = Int64(exactly: lease.generation),
                  let snapshot = snapshotsByRoomID[item.roomID],
                  snapshot.capacityProfileID == item.request.capacityProfile.id
            else { throw V2AtomicRoomWriteBatchError(reason: .admissionState) }
            return try PlainHybridGroupConditionalAppendInput(
                item: item,
                snapshot: snapshot,
                expectedShardLeaseID: leaseID,
                expectedShardGeneration: generation
            )
        }
        let statement = try PlainHybridGroupConditionalAppendStatement(inputs: inputs)
        return try await postgres.withConnection { connection in
            connection.eventLoop.makeFutureWithTask {
                let rows = try await connection.execute(
                    statement,
                    logger: connection.logger
                )
                var decoded: [PlainHybridGroupConditionalAllocationRow] = []
                decoded.reserveCapacity(inputs.count)
                for try await row in rows {
                    decoded.append(row)
                }
                return decoded
            }
        }.get()
    }
}

struct PlainHybridGroupConditionalAppendInput: Sendable {
    let ordinal: Int
    let roomID: UUID
    let senderID: UUID
    let clientMessageID: UUID
    let messageID: UUID
    let eventID: UUID
    let roomShardID: String
    let capacityProfileID: String
    let expectedShardLeaseID: UUID
    let expectedShardGeneration: Int64
    let maximumEligibleMembers: Int64
    let maximumCommandsPerWindow: Int64
    let text: String
    let richEntitiesJSON: String
    let fingerprint: V2SendMessageFingerprint
    let createdAtPostgresMicroseconds: Int64

    init(
        item: OrderedRoomWriteRequest,
        snapshot: V2HybridGroupShardCreditSnapshotCache.Entry,
        expectedShardLeaseID: UUID,
        expectedShardGeneration: Int64
    ) throws {
        let limits = item.request.capacityProfile.limits
        guard let maximumEligibleMembers = Int64(exactly: limits.maxEligibleMembers),
              let maximumCommandsPerWindow = Int64(exactly: limits.maxCommandsPerWindow)
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        ordinal = item.preflightOrdinal
        roomID = item.roomID
        senderID = item.senderID
        clientMessageID = try conditionalAppendUUID(item.request.command.clientMessageID)
        messageID = try conditionalAppendUUID(item.request.identifiers.messageID)
        eventID = try conditionalAppendUUID(item.request.identifiers.eventID)
        roomShardID = snapshot.roomShardID
        capacityProfileID = snapshot.capacityProfileID
        self.expectedShardLeaseID = expectedShardLeaseID
        self.expectedShardGeneration = expectedShardGeneration
        self.maximumEligibleMembers = maximumEligibleMembers
        self.maximumCommandsPerWindow = maximumCommandsPerWindow
        text = item.request.command.text
        richEntitiesJSON = item.request.command.entities.isEmpty
            ? "[]"
            : try roomWriteJSON(item.request.command.entities)
        fingerprint = item.request.command.fingerprint
        createdAtPostgresMicroseconds = try roomWritePostgresMicroseconds(item.request.now)
    }
}

struct PlainHybridGroupConditionalAllocationRow: Sendable {
    let ordinal: Int
    let messageID: UUID
    let roomSequence: Int64
    let timelineSequence: Int64
    let membershipRevision: Int64
}

private func conditionalAppendUUID<Tag>(_ value: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag {
    guard let value = value.uuidValue else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return value
}

/// 单语句的权威普通混合群组追加。
///
/// 进程缓存只贡献不可变的路由与租约标识，且它们会与已锁定的持久行做比较。
/// 它绝不贡献成员、角色、禁言、账号状态或权限判断。
/// 末尾的 `batch_gate` 让 DML 全有或全无：
/// 过期租约、重放、非成员、禁言、停用账号、被拒角色、冻结房间或耗尽的房间窗口，
/// 都不会写入任何房间游标、准入计数器或消息行。
struct PlainHybridGroupConditionalAppendStatement: PostgresPreparedStatement {
    static let name = "im_v2_plain_hybrid_group_conditional_append_v7"
    static let sql = """
        WITH RECURSIVE input AS MATERIALIZED (
            SELECT (source.ordinality - 1)::integer AS ordinal,
                   source.room_id, source.sender_id,
                   source.client_message_id, source.fingerprint_version, source.request_fingerprint, source.message_id,
                   source.event_id, source.room_shard_id,
                   source.capacity_profile_id,
                   source.expected_shard_lease_id,
                   source.expected_shard_generation,
                   source.maximum_eligible_members,
                   source.maximum_commands_per_window,
                   source.text_body,
                   source.rich_entities_json::jsonb AS rich_entities,
                   ((TIMESTAMP '2000-01-01 00:00:00'
                         + (source.created_at_postgres_microseconds / 86400000000) * INTERVAL '1 day'
                         + (source.created_at_postgres_microseconds % 86400000000) * INTERVAL '1 microsecond')
                         AT TIME ZONE 'UTC') AS created_at,
                   hashtextextended(
                       'v2-message-operation:' || source.room_id::text || ':' || source.sender_id::text
                           || ':' || source.client_message_id::text,
                       0
                   ) AS operation_lock_key
            FROM unnest(
                $1::uuid[], $2::uuid[], $3::uuid[], $4::uuid[],
                $5::uuid[], $6::text[], $7::text[], $8::uuid[],
                $9::bigint[], $10::bigint[], $11::bigint[],
                $12::text[], $13::text[], $14::bigint[], $15::smallint[], $16::bytea[]
            ) WITH ORDINALITY AS source(
                room_id, sender_id, client_message_id, message_id, event_id,
                room_shard_id, capacity_profile_id,
                expected_shard_lease_id, expected_shard_generation,
                maximum_eligible_members, maximum_commands_per_window,
                text_body,
                rich_entities_json, created_at_postgres_microseconds, fingerprint_version, request_fingerprint, ordinality
            )
        ), operation_lock_keys AS MATERIALIZED (
            SELECT DISTINCT input.operation_lock_key
            FROM input
        ), ordered_operation_locks AS MATERIALIZED (
            SELECT (row_number() OVER (ORDER BY operation_lock_key) - 1)::integer
                       AS ordinal,
                   operation_lock_key
            FROM operation_lock_keys
        ), operation_locks(ordinal, lock_acquired) AS MATERIALIZED (
            SELECT ordered.ordinal,
                   pg_advisory_xact_lock(ordered.operation_lock_key)
            FROM ordered_operation_locks AS ordered
            WHERE ordered.ordinal = 0

            UNION ALL

            SELECT ordered.ordinal,
                   pg_advisory_xact_lock(ordered.operation_lock_key)
            FROM operation_locks AS previous
            JOIN ordered_operation_locks AS ordered
              ON ordered.ordinal = previous.ordinal + 1
        ), operation_fence AS MATERIALIZED (
            SELECT count(*)::bigint AS acquired_count
            FROM operation_locks
        ), requested_rooms AS MATERIALIZED (
            SELECT DISTINCT input.room_id
            FROM input
        ), locked_room AS MATERIALIZED (
            SELECT room.room_id, room.room_kind, room.room_shard_id,
                   room.capacity_profile_id, room.capacity_class,
                   room.frozen_at, room.room_sequence,
                   room.timeline_sequence, room.membership_revision
            FROM requested_rooms AS requested
            JOIN im_v2.rooms AS room ON room.room_id = requested.room_id
            CROSS JOIN operation_fence AS fence
            WHERE fence.acquired_count
                    = (SELECT count(*) FROM operation_lock_keys)
            ORDER BY room.room_id
            -- Appends only advance non-key sequence columns.  NO KEY UPDATE
            -- still serializes competing appends to one room, while allowing
            -- the KEY SHARE locks taken by receipt foreign-key checks.  Using
            -- FOR UPDATE here needlessly made multi-room append and receipt
            -- batches deadlock; a shared advisory room fence avoided that
            -- deadlock only by serializing otherwise independent operations.
            FOR NO KEY UPDATE OF room
        ), fresh_input AS MATERIALIZED (
            SELECT input.*, room.room_kind, room.capacity_class,
                   room.frozen_at, room.room_sequence,
                   room.timeline_sequence, room.membership_revision,
                   room.room_shard_id AS actual_room_shard_id,
                   room.capacity_profile_id AS actual_capacity_profile_id
            FROM input
            JOIN locked_room AS room ON room.room_id = input.room_id
            WHERE NOT EXISTS (
                SELECT 1
                FROM im_v2.message_send_completions AS message
                WHERE message.sender_user_id = input.sender_id
                  AND message.room_id = input.room_id
                  AND message.client_message_id = input.client_message_id
            )
        ), locked_admission AS MATERIALIZED (
            SELECT room.room_id, admission.eligible_member_count,
                   admission.command_window_limit,
                   admission.command_window_used,
                   admission.shard_lease_id,
                   admission.shard_lease_generation
            FROM locked_room AS room
            JOIN im_v2.room_admission AS admission
              ON admission.room_id = room.room_id
            ORDER BY room.room_id
            FOR UPDATE OF admission
        ), locked_actor AS MATERIALIZED (
            SELECT fresh.ordinal
            FROM fresh_input AS fresh
            JOIN locked_admission AS admission
              ON admission.room_id = fresh.room_id
            JOIN im_v2.room_memberships AS membership
              ON membership.room_id = fresh.room_id
             AND membership.user_id = fresh.sender_id
             AND membership.joined_revision <= fresh.membership_revision
             AND (membership.left_revision IS NULL
                  OR membership.left_revision > fresh.membership_revision)
            WHERE membership.role IN ('owner', 'admin', 'member')
              AND EXISTS (
                  SELECT 1
                  FROM im_v2.public_user_profiles AS profile
                  WHERE profile.user_id = fresh.sender_id
                    AND profile.state = 'active'
                    AND NOT EXISTS (
                        SELECT 1
                        FROM im_v2.account_disables AS disabled
                        WHERE disabled.user_id = profile.user_id
                    )
              )
              AND NOT EXISTS (
                  SELECT 1
                  FROM im_v2.room_member_mutes AS mute
                  WHERE mute.room_id = fresh.room_id
                    AND mute.user_id = fresh.sender_id
                    AND mute.mute_until > fresh.created_at
              )
              AND (
                  membership.role = 'owner'
                  OR EXISTS (
                      SELECT 1
                      FROM im_v2.group_role_permissions AS permission
                      WHERE permission.room_id = fresh.room_id
                        AND permission.role = membership.role
                        AND permission.permission = 'send_messages'
                  )
                  OR NOT EXISTS (
                      SELECT 1
                      FROM (SELECT room_id, role FROM im_v2.group_role_policies UNION ALL SELECT room_id, role FROM im_v2.group_role_permissions) AS operation
                      WHERE operation.room_id = fresh.room_id
                        AND operation.role = membership.role
                  )
              )
            ORDER BY fresh.room_id, fresh.sender_id, fresh.ordinal
            FOR UPDATE OF membership
        ), eligible AS MATERIALIZED (
            SELECT fresh.*, admission.eligible_member_count,
                   admission.command_window_limit,
                   admission.command_window_used
            FROM fresh_input AS fresh
            JOIN locked_actor AS actor ON actor.ordinal = fresh.ordinal
            JOIN locked_admission AS admission
              ON admission.room_id = fresh.room_id
            JOIN im_v2.shard_admission_pools AS shard
              ON shard.room_shard_id = fresh.room_shard_id
             AND shard.capacity_profile_id = fresh.capacity_profile_id
             AND shard.lease_id = fresh.expected_shard_lease_id
             AND shard.generation = fresh.expected_shard_generation
             AND shard.valid_until > fresh.created_at
            WHERE fresh.room_kind = 'group'
              AND fresh.capacity_class = 'large'
              AND fresh.frozen_at IS NULL

              AND fresh.actual_room_shard_id = fresh.room_shard_id
              AND fresh.actual_capacity_profile_id = fresh.capacity_profile_id
              AND admission.shard_lease_id = fresh.expected_shard_lease_id
              AND admission.shard_lease_generation
                    = fresh.expected_shard_generation
              AND admission.eligible_member_count
                    <= fresh.maximum_eligible_members
              AND admission.command_window_limit
                    = fresh.maximum_commands_per_window
        ), room_delta AS MATERIALIZED (
            SELECT eligible.room_id,
                   count(*)::bigint AS message_count,
                   min(eligible.room_sequence) AS room_sequence,
                   min(eligible.timeline_sequence) AS timeline_sequence,
                   min(eligible.command_window_used) AS command_window_used,
                   min(eligible.command_window_limit) AS command_window_limit
            FROM eligible
            GROUP BY eligible.room_id
        ), batch_gate AS MATERIALIZED (
            SELECT count(*) = (SELECT count(*) FROM input)
               AND NOT EXISTS (
                   SELECT 1
                   FROM room_delta
                   WHERE room_sequence > 9223372036854775807 - message_count
                      OR timeline_sequence > 9223372036854775807 - message_count
                      OR command_window_used > command_window_limit - message_count
               ) AS allowed
            FROM eligible
        ), allocated AS MATERIALIZED (
            SELECT eligible.*,
                   eligible.room_sequence
                       + row_number() OVER (
                           PARTITION BY eligible.room_id
                           ORDER BY eligible.ordinal
                       ) AS allocated_room_sequence,
                   eligible.timeline_sequence
                       + row_number() OVER (
                           PARTITION BY eligible.room_id
                           ORDER BY eligible.ordinal
                       ) AS allocated_timeline_sequence
            FROM eligible
            CROSS JOIN batch_gate
            WHERE batch_gate.allowed
        ), room_update AS (
            UPDATE im_v2.rooms AS room
            SET room_sequence = room.room_sequence + delta.message_count,
                timeline_sequence = room.timeline_sequence + delta.message_count
            FROM room_delta AS delta
            CROSS JOIN batch_gate
            WHERE batch_gate.allowed
              AND room.room_id = delta.room_id
            RETURNING room.room_id
        ), admission_update AS (
            UPDATE im_v2.room_admission AS admission
            SET command_window_used
                    = admission.command_window_used + delta.message_count
            FROM room_delta AS delta
            JOIN room_update ON room_update.room_id = delta.room_id
            WHERE admission.room_id = delta.room_id
            RETURNING admission.room_id
        ), message_insert AS (
            INSERT INTO im_v2.messages
                (message_id, room_id, room_sequence, timeline_sequence,
                 sender_user_id, client_message_id, text_body,
                 rich_entities, created_at, accepted_event_id,
                 accepted_event_storage, accepted_membership_revision)
            SELECT allocated.message_id, allocated.room_id,
                   allocated.allocated_room_sequence,
                   allocated.allocated_timeline_sequence,
                   allocated.sender_id, allocated.client_message_id,
                   allocated.text_body, allocated.rich_entities,
                   allocated.created_at, CASE WHEN allocated.allocated_room_sequence = allocated.allocated_timeline_sequence THEN allocated.event_id END,
                   CASE WHEN allocated.allocated_room_sequence = allocated.allocated_timeline_sequence THEN 'message_row' ELSE 'room_event' END,
                   CASE WHEN allocated.allocated_room_sequence = allocated.allocated_timeline_sequence THEN allocated.membership_revision END
            FROM allocated
            JOIN admission_update
              ON admission_update.room_id = allocated.room_id
            RETURNING *
        )
        \(v2ConditionalHybridGroupSendCompletionCTE)
        SELECT allocated.ordinal, inserted.message_id,
               inserted.room_sequence, inserted.timeline_sequence,
               allocated.membership_revision AS accepted_membership_revision
        FROM allocated
        JOIN message_insert AS inserted
          ON inserted.message_id = allocated.message_id
        ORDER BY allocated.ordinal
        """

    typealias Row = PlainHybridGroupConditionalAllocationRow

    let inputs: [PlainHybridGroupConditionalAppendInput]

    init(inputs: [PlainHybridGroupConditionalAppendInput]) throws {
        guard !inputs.isEmpty,
              inputs.enumerated().allSatisfy({ $0.offset == $0.element.ordinal })
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        self.inputs = inputs
    }

    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 16)
        bindings.append(inputs.map(\.roomID))
        bindings.append(inputs.map(\.senderID))
        bindings.append(inputs.map(\.clientMessageID))
        bindings.append(inputs.map(\.messageID))
        bindings.append(inputs.map(\.eventID))
        bindings.append(inputs.map(\.roomShardID))
        bindings.append(inputs.map(\.capacityProfileID))
        bindings.append(inputs.map(\.expectedShardLeaseID))
        bindings.append(inputs.map(\.expectedShardGeneration))
        bindings.append(inputs.map(\.maximumEligibleMembers))
        bindings.append(inputs.map(\.maximumCommandsPerWindow))
        bindings.append(inputs.map(\.text))
        bindings.append(inputs.map(\.richEntitiesJSON))
        bindings.append(inputs.map(\.createdAtPostgresMicroseconds))
        bindings.append(inputs.map { Int16($0.fingerprint.version) })
        bindings.append(inputs.map { ByteBuffer(bytes: $0.fingerprint.digest) })
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> Row {
        let decoded = try row.decode((Int32, UUID, Int64, Int64, Int64).self)
        return .init(
            ordinal: Int(decoded.0),
            messageID: decoded.1,
            roomSequence: decoded.2,
            timelineSequence: decoded.3,
            membershipRevision: decoded.4
        )
    }
}
