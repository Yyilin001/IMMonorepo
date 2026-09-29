import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core
import NIOCore
import PostgresNIO
import SQLKit

// 在 Store 借用的事务上执行快速私聊追加。
// 幂等锁、所有者锁、提交和额度结算仍由 Store 负责。
enum FastPlainDirectRoomLogWritePath {
    static func persist(
        inputs: [FastPlainDirectRoomLogAppendInput],
        maximumStrangerMessages: Int,
        sql: any SQLDatabase
    ) async throws -> [FastPlainDirectRoomLogAllocationRow] {
        let expectedCount = Int64(inputs.count)
        // SQLKit 的原始查询路径使用未命名的扩展协议语句。
        // 因此 PostgreSQL 每个微批都要重新规划这一大型固定 CTE；
        // 在每秒 6,000 条消息的测量中，规划耗时 2.57 毫秒，执行耗时 5.81 毫秒。
        // 命名的 PostgresNIO 语句保持精确的事务和绑定契约，
        // 同时允许连接池中各连接复用执行计划。数据库测试替身仍用 SQLKit 分支；
        // 生产 PostgreSQL 必须使用此分支。
        if let postgres = sql as? any PostgresDatabase {
            let statement = FastPlainDirectRoomLogAppendStatement(
                inputs: inputs,
                maximumStrangerMessages: maximumStrangerMessages
            )
            let result = try await postgres.withConnection { connection in
                connection.eventLoop.makeFutureWithTask {
                    let rows = try await connection.execute(
                        statement,
                        logger: connection.logger
                    )
                    var decoded: [FastPlainDirectRoomLogAllocationRow] = []
                    decoded.reserveCapacity(inputs.count)
                    for try await row in rows {
                        decoded.append(row)
                    }
                    return decoded
                }
            }.get()
            guard result.count == Int(expectedCount),
                  result.enumerated().allSatisfy({ $0.offset == $0.element.ordinal })
            else {
                throw V2AtomicRoomWriteBatchError(reason: .conditionalWriteMismatch)
            }
            return result
        }
        let result = try await sql.raw("""
            WITH input AS MATERIALIZED (
                SELECT (input.ordinality - 1)::integer AS ordinal,
                       input.room_id, input.sender_id,
                       input.recipient_id, input.message_id, input.event_id,
                       input.client_message_id, input.fingerprint_version,
                       decode(input.request_fingerprint_base64, 'base64') AS request_fingerprint,
                       input.expected_membership_revision,
                       input.expected_direct_pair_revision,
                       input.expected_sender_policy_revision,
                       input.expected_recipient_policy_revision,
                       input.room_shard_id, input.capacity_profile_id,
                       input.expected_shard_lease_id,
                       input.expected_shard_generation,
                       input.requires_stranger_quota,
                       input.uses_room_admission_credits,
                       input.text_body, input.rich_entities_json::jsonb AS rich_entities,
                       input.created_at_postgres_microseconds, input.window_start,
                       ((TIMESTAMP '2000-01-01 00:00:00'
                         + (input.created_at_postgres_microseconds / 86400000000) * INTERVAL '1 day'
                         + (input.created_at_postgres_microseconds % 86400000000) * INTERVAL '1 microsecond')
                         AT TIME ZONE 'UTC') AS created_at
                FROM unnest(
                    \(bind: inputs.map(\.roomID))::uuid[],
                    \(bind: inputs.map(\.senderID))::uuid[],
                    \(bind: inputs.map(\.recipientID))::uuid[],
                    \(bind: inputs.map(\.messageID))::uuid[],
                    \(bind: inputs.map(\.eventID))::uuid[],
                    \(bind: inputs.map(\.clientMessageID))::uuid[],
                    \(bind: inputs.map(\.expectedMembershipRevision))::bigint[],
                    \(bind: inputs.map(\.expectedDirectPairRevision))::bigint[],
                    \(bind: inputs.map(\.expectedSenderPolicyRevision))::bigint[],
                    \(bind: inputs.map(\.expectedRecipientPolicyRevision))::bigint[],
                    \(bind: inputs.map(\.roomShardID))::text[],
                    \(bind: inputs.map(\.capacityProfileID))::text[],
                    \(bind: inputs.map(\.expectedShardLeaseID))::uuid[],
                    \(bind: inputs.map(\.expectedShardGeneration))::bigint[],
                    \(bind: inputs.map(\.requiresStrangerQuota))::boolean[],
                    \(bind: inputs.map(\.usesRoomAdmissionCredits))::boolean[],
                    \(bind: inputs.map(\.text))::text[],
                    \(bind: inputs.map(\.entitiesJSON))::text[],
                    \(bind: inputs.map(\.createdAtPostgresMicroseconds))::bigint[],
                    \(bind: inputs.map(\.windowStart))::timestamptz[],
                    \(bind: inputs.map { Int16($0.fingerprint.version) })::smallint[],
                    \(bind: inputs.map { $0.fingerprint.digest.base64EncodedString() })::text[]
                ) WITH ORDINALITY AS input(
                    room_id, sender_id, recipient_id, message_id, event_id,
                    client_message_id, expected_membership_revision,
                    expected_direct_pair_revision, expected_sender_policy_revision,
                    expected_recipient_policy_revision, room_shard_id,
                    capacity_profile_id, expected_shard_lease_id,
                    expected_shard_generation, requires_stranger_quota,
                    uses_room_admission_credits, text_body, rich_entities_json,
                    created_at_postgres_microseconds, window_start, fingerprint_version, request_fingerprint_base64, ordinality
                )
            ), locked_room AS MATERIALIZED (
                SELECT input.*, room.room_sequence, room.timeline_sequence,
                       room.membership_revision, room.room_kind,
                       room.room_shard_id AS actual_room_shard_id,
                       room.capacity_profile_id AS actual_capacity_profile_id,
                       room.frozen_at
                FROM input
                JOIN im_v2.rooms AS room ON room.room_id = input.room_id
                ORDER BY room.room_id
                FOR UPDATE OF room
            ), fresh_room AS MATERIALIZED (
                SELECT room.*
                FROM locked_room AS room
                WHERE NOT EXISTS (
                    SELECT 1
                    FROM im_v2.message_send_completions AS message
                    WHERE message.sender_user_id = room.sender_id
                  AND message.room_id = room.room_id
                      AND message.client_message_id = room.client_message_id
                )
                  AND NOT EXISTS (
                    SELECT 1
                    FROM im_v2.direct_message_denials AS denial
                    WHERE denial.sender_user_id = room.sender_id
                  AND denial.room_id = room.room_id
                      AND denial.client_message_id = room.client_message_id
                )
            ), locked_membership AS MATERIALIZED (
                SELECT room.ordinal
                FROM fresh_room AS room
                JOIN im_v2.room_memberships AS membership
                  ON membership.room_id = room.room_id
                 AND membership.user_id = room.sender_id
                 AND membership.joined_revision <= room.membership_revision
                 AND (membership.left_revision IS NULL
                      OR membership.left_revision > room.membership_revision)
                WHERE membership.role IN ('owner', 'admin', 'member')
                  AND NOT EXISTS (
                      SELECT 1
                      FROM im_v2.room_member_mutes AS mute
                      WHERE mute.room_id = room.room_id
                        AND mute.user_id = room.sender_id
                        AND mute.mute_until > room.created_at
                  )
                FOR UPDATE OF membership
            ), locked_pair AS MATERIALIZED (
                SELECT room.ordinal
                FROM fresh_room AS room
                JOIN locked_membership AS membership ON membership.ordinal = room.ordinal
                JOIN im_v2.direct_room_pairs AS pair
                  ON pair.room_id = room.room_id
                 AND ((pair.lower_user_id = room.sender_id
                       AND pair.higher_user_id = room.recipient_id)
                      OR (pair.higher_user_id = room.sender_id
                          AND pair.lower_user_id = room.recipient_id))
                 AND pair.direct_policy_revision = room.expected_direct_pair_revision
                WHERE COALESCE((
                    SELECT count(*) = 2
                        AND bool_and(member.user_id IN (pair.lower_user_id, pair.higher_user_id))
                    FROM (
                        SELECT user_id FROM im_v2.room_memberships
                        WHERE room_id = room.room_id
                          AND joined_revision <= room.membership_revision
                          AND (left_revision IS NULL OR left_revision > room.membership_revision)
                        LIMIT 3
                    ) AS member
                ), FALSE)
                FOR UPDATE OF pair
            ), locked_policy_versions AS MATERIALIZED (
                SELECT room.ordinal
                FROM fresh_room AS room
                JOIN locked_pair AS pair ON pair.ordinal = room.ordinal
                JOIN im_v2.user_direct_send_policy_versions AS sender_version
                  ON sender_version.user_id = room.sender_id
                 AND sender_version.revision = room.expected_sender_policy_revision
                JOIN im_v2.user_direct_send_policy_versions AS recipient_version
                  ON recipient_version.user_id = room.recipient_id
                 AND recipient_version.revision = room.expected_recipient_policy_revision
                -- Policy mutations update these revision rows.  `FOR SHARE`
                -- (not `FOR KEY SHARE`) makes this statement serialize with
                -- those non-key updates, so an accepted append is ordered
                -- wholly before or wholly after a permission change.
                FOR SHARE OF sender_version, recipient_version
            ), locked_active_profiles AS MATERIALIZED (
                SELECT room.ordinal
                FROM fresh_room AS room
                JOIN locked_policy_versions AS policy ON policy.ordinal = room.ordinal
                JOIN im_v2.public_user_profiles AS sender_profile
                  ON sender_profile.user_id = room.sender_id
                 AND sender_profile.state = 'active'
                JOIN im_v2.public_user_profiles AS recipient_profile
                  ON recipient_profile.user_id = room.recipient_id
                 AND recipient_profile.state = 'active'
                WHERE NOT EXISTS (
                    SELECT 1
                    FROM im_v2.account_disables AS disabled
                    WHERE disabled.user_id = room.sender_id
                )
                  AND NOT EXISTS (
                    SELECT 1
                    FROM im_v2.account_disables AS disabled
                    WHERE disabled.user_id = room.recipient_id
                )
                FOR SHARE OF sender_profile, recipient_profile
            ), locked_admission AS MATERIALIZED (
                SELECT room.ordinal,
                       admission.command_window_used,
                       admission.command_window_limit,
                       admission.shard_lease_id,
                       admission.shard_lease_generation
                FROM fresh_room AS room
                JOIN locked_active_profiles AS profile ON profile.ordinal = room.ordinal
                JOIN im_v2.room_admission AS admission ON admission.room_id = room.room_id
                WHERE room.uses_room_admission_credits
                   OR admission.command_window_used < admission.command_window_limit
                FOR UPDATE OF admission
            ), validated_shard AS MATERIALIZED (
                SELECT room.ordinal
                FROM fresh_room AS room
                JOIN locked_admission AS admission ON admission.ordinal = room.ordinal
                JOIN im_v2.shard_admission_pools AS shard
                  ON shard.room_shard_id = room.room_shard_id
                 AND shard.capacity_profile_id = room.capacity_profile_id
                 AND shard.lease_id = room.expected_shard_lease_id
                 AND shard.generation = room.expected_shard_generation
                 AND shard.valid_until > room.created_at
                WHERE admission.shard_lease_id = room.expected_shard_lease_id
                  AND admission.shard_lease_generation = room.expected_shard_generation
                -- Do not retain a KEY SHARE lock here. The final aggregate
                -- reservation revalidates this lease and capacity with an
                -- UPDATE in the same transaction. Retaining shared locks and
                -- upgrading them there lets concurrent batches deadlock even
                -- when that UPDATE acquires different shard rows in a stable
                -- order. Any intervening lease change makes the reservation
                -- fail and rolls back every provisional write below.
            ), eligible AS MATERIALIZED (
                SELECT room.*
                FROM fresh_room AS room
                JOIN validated_shard AS shard ON shard.ordinal = room.ordinal
                WHERE room.room_kind = 'direct'
                  AND room.frozen_at IS NULL
                  AND room.membership_revision = room.expected_membership_revision
                  AND room.actual_room_shard_id = room.room_shard_id
                  AND room.actual_capacity_profile_id = room.capacity_profile_id
            ), stranger_quota AS (
                INSERT INTO im_v2.stranger_message_windows
                    (sender_user_id, recipient_user_id, window_started_at, message_count)
                SELECT eligible.sender_id, eligible.recipient_id,
                       eligible.created_at, 1
                FROM eligible
                WHERE eligible.requires_stranger_quota
                ON CONFLICT (sender_user_id, recipient_user_id) DO UPDATE
                SET window_started_at = CASE
                        WHEN im_v2.stranger_message_windows.window_started_at
                             <= (SELECT input.window_start FROM input
                             WHERE input.sender_id = EXCLUDED.sender_user_id
                               AND input.recipient_id = EXCLUDED.recipient_user_id)
                        THEN EXCLUDED.window_started_at
                        ELSE im_v2.stranger_message_windows.window_started_at
                    END,
                    message_count = CASE
                        WHEN im_v2.stranger_message_windows.window_started_at
                             <= (SELECT input.window_start FROM input
                             WHERE input.sender_id = EXCLUDED.sender_user_id
                               AND input.recipient_id = EXCLUDED.recipient_user_id)
                        THEN 1
                        ELSE im_v2.stranger_message_windows.message_count + 1
                    END
                WHERE im_v2.stranger_message_windows.window_started_at
                          <= (SELECT input.window_start FROM input
                             WHERE input.sender_id = EXCLUDED.sender_user_id
                               AND input.recipient_id = EXCLUDED.recipient_user_id)
                   OR im_v2.stranger_message_windows.message_count
                          < \(bind: maximumStrangerMessages)
                RETURNING sender_user_id, recipient_user_id
            ), quota_gate AS MATERIALIZED (
                SELECT eligible.*
                FROM eligible
                WHERE NOT eligible.requires_stranger_quota
                UNION ALL
                SELECT eligible.*
                FROM eligible
                JOIN stranger_quota AS quota
                  ON quota.sender_user_id = eligible.sender_id
                 AND quota.recipient_user_id = eligible.recipient_id
                WHERE eligible.requires_stranger_quota
            ), room_update AS (
                UPDATE im_v2.rooms AS room
                SET room_sequence = room.room_sequence + 1,
                    timeline_sequence = room.timeline_sequence + 1
                FROM quota_gate
                WHERE room.room_id = quota_gate.room_id
                  AND room.room_sequence < \(bind: Int64.max)
                  AND room.timeline_sequence < \(bind: Int64.max)
                RETURNING room.room_id, room.room_sequence,
                          room.timeline_sequence
            ), admission_update AS (
                UPDATE im_v2.room_admission AS admission
                SET command_window_used = admission.command_window_used + 1
                FROM eligible
                JOIN room_update ON room_update.room_id = eligible.room_id
                WHERE admission.room_id = eligible.room_id
                  AND NOT eligible.uses_room_admission_credits
                RETURNING admission.room_id
            ), admission_gate AS (
                SELECT room_update.room_id
                FROM room_update
                JOIN eligible ON eligible.room_id = room_update.room_id
                WHERE eligible.uses_room_admission_credits
                UNION ALL
                SELECT room_id FROM admission_update
            ), message_insert AS (
                INSERT INTO im_v2.messages
                    (message_id, room_id, room_sequence, timeline_sequence,
                     sender_user_id, client_message_id, text_body,
                     rich_entities, reply_to_message_id,
                     forwarded_from_message_id, forwarded_from_user_id,
                     created_at, accepted_event_id, accepted_event_storage,
                     accepted_membership_revision)
                SELECT eligible.message_id, eligible.room_id,
                       room_update.room_sequence,
                       room_update.timeline_sequence,
                       eligible.sender_id, eligible.client_message_id,
                       eligible.text_body, eligible.rich_entities, NULL,
                       NULL, NULL, eligible.created_at, CASE WHEN room_update.room_sequence = room_update.timeline_sequence THEN eligible.event_id END,
                   CASE WHEN room_update.room_sequence = room_update.timeline_sequence THEN 'message_row' ELSE 'room_event' END,
                   CASE WHEN room_update.room_sequence = room_update.timeline_sequence THEN eligible.expected_membership_revision END
                FROM eligible
                JOIN room_update ON room_update.room_id = eligible.room_id
                JOIN admission_gate ON admission_gate.room_id = eligible.room_id
                RETURNING *
            )
            \(unsafeRaw: v2FastDirectRoomLogSendCompletionCTE)
            SELECT input.ordinal, room_update.room_sequence,
                   room_update.timeline_sequence
            FROM input
            JOIN room_update ON room_update.room_id = input.room_id
            JOIN admission_gate ON admission_gate.room_id = input.room_id
            JOIN message_insert ON message_insert.message_id = input.message_id
            ORDER BY input.ordinal
            """).all(decoding: FastPlainDirectRoomLogAllocationRow.self)
        guard result.count == Int(expectedCount),
              result.enumerated().allSatisfy({ $0.offset == $0.element.ordinal })
        else {
            throw V2AtomicRoomWriteBatchError(reason: .conditionalWriteMismatch)
        }
        return result
    }
}

/// 不变式快速追加语句的具名、连接级缓存形式。
///
/// 每当 `sql` 变化时都要提升 `name`。
/// PostgresNIO 会在每条物理前台连接上准备一次，然后用新的数组绑定执行；
/// 该语句既不拥有连接，也不跨越外层 Fluent 事务边界。
private struct FastPlainDirectRoomLogAppendStatement: PostgresPreparedStatement {
    static let name = "im_v2_fast_plain_direct_room_log_append_v7"
    static let sql = """
        WITH input AS MATERIALIZED (
            SELECT (input.ordinality - 1)::integer AS ordinal,
                   input.room_id, input.sender_id,
                   input.recipient_id, input.message_id, input.event_id,
                   input.client_message_id, input.fingerprint_version, input.request_fingerprint,
                   input.expected_membership_revision,
                   input.expected_direct_pair_revision,
                   input.expected_sender_policy_revision,
                   input.expected_recipient_policy_revision,
                   input.room_shard_id, input.capacity_profile_id,
                   input.expected_shard_lease_id,
                   input.expected_shard_generation,
                   input.requires_stranger_quota,
                   input.uses_room_admission_credits,
                   input.text_body, input.rich_entities_json::jsonb AS rich_entities,
                   input.created_at_postgres_microseconds, input.window_start,
                   ((TIMESTAMP '2000-01-01 00:00:00'
                         + (input.created_at_postgres_microseconds / 86400000000) * INTERVAL '1 day'
                         + (input.created_at_postgres_microseconds % 86400000000) * INTERVAL '1 microsecond')
                         AT TIME ZONE 'UTC') AS created_at
            FROM unnest(
                $1::uuid[], $2::uuid[], $3::uuid[], $4::uuid[],
                $5::uuid[], $6::uuid[], $7::bigint[], $8::bigint[],
                $9::bigint[], $10::bigint[], $11::text[], $12::text[],
                $13::uuid[], $14::bigint[], $15::boolean[], $16::boolean[],
                $17::text[], $18::text[], $19::bigint[], $20::timestamptz[], $22::smallint[], $23::bytea[]
            ) WITH ORDINALITY AS input(
                room_id, sender_id, recipient_id, message_id, event_id,
                client_message_id, expected_membership_revision,
                expected_direct_pair_revision, expected_sender_policy_revision,
                expected_recipient_policy_revision, room_shard_id,
                capacity_profile_id, expected_shard_lease_id,
                expected_shard_generation, requires_stranger_quota,
                uses_room_admission_credits, text_body, rich_entities_json,
                created_at_postgres_microseconds, window_start, fingerprint_version, request_fingerprint, ordinality
            )
        ), locked_room AS MATERIALIZED (
            SELECT input.*, room.room_sequence, room.timeline_sequence,
                   room.membership_revision, room.room_kind,
                   room.room_shard_id AS actual_room_shard_id,
                   room.capacity_profile_id AS actual_capacity_profile_id,
                   room.frozen_at
            FROM input
            JOIN im_v2.rooms AS room ON room.room_id = input.room_id
            ORDER BY room.room_id
            FOR UPDATE OF room
        ), fresh_room AS MATERIALIZED (
            SELECT room.*
            FROM locked_room AS room
            WHERE NOT EXISTS (
                SELECT 1
                FROM im_v2.message_send_completions AS message
                WHERE message.sender_user_id = room.sender_id
                  AND message.room_id = room.room_id
                  AND message.client_message_id = room.client_message_id
            )
              AND NOT EXISTS (
                SELECT 1
                FROM im_v2.direct_message_denials AS denial
                WHERE denial.sender_user_id = room.sender_id
                  AND denial.room_id = room.room_id
                  AND denial.client_message_id = room.client_message_id
            )
        ), locked_membership AS MATERIALIZED (
            SELECT room.ordinal
            FROM fresh_room AS room
            JOIN im_v2.room_memberships AS membership
              ON membership.room_id = room.room_id
             AND membership.user_id = room.sender_id
             AND membership.joined_revision <= room.membership_revision
             AND (membership.left_revision IS NULL
                  OR membership.left_revision > room.membership_revision)
            WHERE membership.role IN ('owner', 'admin', 'member')
              AND NOT EXISTS (
                SELECT 1
                FROM im_v2.room_member_mutes AS mute
                WHERE mute.room_id = room.room_id
                  AND mute.user_id = room.sender_id
                  AND mute.mute_until > room.created_at
              )
            FOR UPDATE OF membership
        ), locked_pair AS MATERIALIZED (
            SELECT room.ordinal
            FROM fresh_room AS room
            JOIN locked_membership AS membership ON membership.ordinal = room.ordinal
            JOIN im_v2.direct_room_pairs AS pair
              ON pair.room_id = room.room_id
             AND ((pair.lower_user_id = room.sender_id
                   AND pair.higher_user_id = room.recipient_id)
                  OR (pair.higher_user_id = room.sender_id
                      AND pair.lower_user_id = room.recipient_id))
             AND pair.direct_policy_revision = room.expected_direct_pair_revision
            WHERE COALESCE((
                SELECT count(*) = 2
                    AND bool_and(member.user_id IN (pair.lower_user_id, pair.higher_user_id))
                FROM (
                    SELECT user_id FROM im_v2.room_memberships
                    WHERE room_id = room.room_id
                      AND joined_revision <= room.membership_revision
                      AND (left_revision IS NULL OR left_revision > room.membership_revision)
                    LIMIT 3
                ) AS member
            ), FALSE)
            FOR UPDATE OF pair
        ), locked_policy_versions AS MATERIALIZED (
            SELECT room.ordinal
            FROM fresh_room AS room
            JOIN locked_pair AS pair ON pair.ordinal = room.ordinal
            JOIN im_v2.user_direct_send_policy_versions AS sender_version
              ON sender_version.user_id = room.sender_id
             AND sender_version.revision = room.expected_sender_policy_revision
            JOIN im_v2.user_direct_send_policy_versions AS recipient_version
              ON recipient_version.user_id = room.recipient_id
             AND recipient_version.revision = room.expected_recipient_policy_revision
            FOR SHARE OF sender_version, recipient_version
        ), locked_active_profiles AS MATERIALIZED (
            SELECT room.ordinal
            FROM fresh_room AS room
            JOIN locked_policy_versions AS policy ON policy.ordinal = room.ordinal
            JOIN im_v2.public_user_profiles AS sender_profile
              ON sender_profile.user_id = room.sender_id
             AND sender_profile.state = 'active'
            JOIN im_v2.public_user_profiles AS recipient_profile
              ON recipient_profile.user_id = room.recipient_id
             AND recipient_profile.state = 'active'
            WHERE NOT EXISTS (
                SELECT 1 FROM im_v2.account_disables AS disabled
                WHERE disabled.user_id = room.sender_id
            )
              AND NOT EXISTS (
                SELECT 1 FROM im_v2.account_disables AS disabled
                WHERE disabled.user_id = room.recipient_id
            )
            FOR SHARE OF sender_profile, recipient_profile
        ), locked_admission AS MATERIALIZED (
            SELECT room.ordinal,
                   admission.command_window_used,
                   admission.command_window_limit,
                   admission.shard_lease_id,
                   admission.shard_lease_generation
            FROM fresh_room AS room
            JOIN locked_active_profiles AS profile ON profile.ordinal = room.ordinal
            JOIN im_v2.room_admission AS admission ON admission.room_id = room.room_id
            WHERE room.uses_room_admission_credits
               OR admission.command_window_used < admission.command_window_limit
            FOR UPDATE OF admission
        ), validated_shard AS MATERIALIZED (
            SELECT room.ordinal
            FROM fresh_room AS room
            JOIN locked_admission AS admission ON admission.ordinal = room.ordinal
            JOIN im_v2.shard_admission_pools AS shard
              ON shard.room_shard_id = room.room_shard_id
             AND shard.capacity_profile_id = room.capacity_profile_id
             AND shard.lease_id = room.expected_shard_lease_id
             AND shard.generation = room.expected_shard_generation
             AND shard.valid_until > room.created_at
            WHERE admission.shard_lease_id = room.expected_shard_lease_id
              AND admission.shard_lease_generation = room.expected_shard_generation
        ), eligible AS MATERIALIZED (
            SELECT room.*
            FROM fresh_room AS room
            JOIN validated_shard AS shard ON shard.ordinal = room.ordinal
            WHERE room.room_kind = 'direct'
              AND room.frozen_at IS NULL
              AND room.membership_revision = room.expected_membership_revision
              AND room.actual_room_shard_id = room.room_shard_id
              AND room.actual_capacity_profile_id = room.capacity_profile_id
        ), stranger_quota AS (
            INSERT INTO im_v2.stranger_message_windows
                (sender_user_id, recipient_user_id, window_started_at, message_count)
            SELECT eligible.sender_id, eligible.recipient_id,
                   eligible.created_at, 1
            FROM eligible
            WHERE eligible.requires_stranger_quota
            ON CONFLICT (sender_user_id, recipient_user_id) DO UPDATE
            SET window_started_at = CASE
                    WHEN im_v2.stranger_message_windows.window_started_at
                         <= (SELECT input.window_start FROM input
                             WHERE input.sender_id = EXCLUDED.sender_user_id
                               AND input.recipient_id = EXCLUDED.recipient_user_id)
                    THEN EXCLUDED.window_started_at
                    ELSE im_v2.stranger_message_windows.window_started_at
                END,
                message_count = CASE
                    WHEN im_v2.stranger_message_windows.window_started_at
                         <= (SELECT input.window_start FROM input
                             WHERE input.sender_id = EXCLUDED.sender_user_id
                               AND input.recipient_id = EXCLUDED.recipient_user_id)
                    THEN 1
                    ELSE im_v2.stranger_message_windows.message_count + 1
                END
            WHERE im_v2.stranger_message_windows.window_started_at
                      <= (SELECT input.window_start FROM input
                             WHERE input.sender_id = EXCLUDED.sender_user_id
                               AND input.recipient_id = EXCLUDED.recipient_user_id)
               OR im_v2.stranger_message_windows.message_count < $21
            RETURNING sender_user_id, recipient_user_id
        ), quota_gate AS MATERIALIZED (
            SELECT eligible.*
            FROM eligible
            WHERE NOT eligible.requires_stranger_quota
            UNION ALL
            SELECT eligible.*
            FROM eligible
            JOIN stranger_quota AS quota
              ON quota.sender_user_id = eligible.sender_id
             AND quota.recipient_user_id = eligible.recipient_id
            WHERE eligible.requires_stranger_quota
        ), room_update AS (
            UPDATE im_v2.rooms AS room
            SET room_sequence = room.room_sequence + 1,
                timeline_sequence = room.timeline_sequence + 1
            FROM quota_gate
            WHERE room.room_id = quota_gate.room_id
              AND room.room_sequence < 9223372036854775807
              AND room.timeline_sequence < 9223372036854775807
            RETURNING room.room_id, room.room_sequence,
                      room.timeline_sequence
        ), admission_update AS (
            UPDATE im_v2.room_admission AS admission
            SET command_window_used = admission.command_window_used + 1
            FROM eligible
            JOIN room_update ON room_update.room_id = eligible.room_id
            WHERE admission.room_id = eligible.room_id
              AND NOT eligible.uses_room_admission_credits
            RETURNING admission.room_id
        ), admission_gate AS (
            SELECT room_update.room_id
            FROM room_update
            JOIN eligible ON eligible.room_id = room_update.room_id
            WHERE eligible.uses_room_admission_credits
            UNION ALL
            SELECT room_id FROM admission_update
        ), message_insert AS (
            INSERT INTO im_v2.messages
                (message_id, room_id, room_sequence, timeline_sequence,
                 sender_user_id, client_message_id, text_body,
                 rich_entities, reply_to_message_id,
                 forwarded_from_message_id, forwarded_from_user_id,
                 created_at, accepted_event_id, accepted_event_storage,
                 accepted_membership_revision)
            SELECT eligible.message_id, eligible.room_id,
                   room_update.room_sequence,
                   room_update.timeline_sequence,
                   eligible.sender_id, eligible.client_message_id,
                   eligible.text_body, eligible.rich_entities, NULL,
                   NULL, NULL, eligible.created_at, CASE WHEN room_update.room_sequence = room_update.timeline_sequence THEN eligible.event_id END,
                   CASE WHEN room_update.room_sequence = room_update.timeline_sequence THEN 'message_row' ELSE 'room_event' END,
                   CASE WHEN room_update.room_sequence = room_update.timeline_sequence THEN eligible.expected_membership_revision END
            FROM eligible
            JOIN room_update ON room_update.room_id = eligible.room_id
            JOIN admission_gate ON admission_gate.room_id = eligible.room_id
            RETURNING *
        )
        \(v2FastDirectRoomLogSendCompletionCTE)
        SELECT input.ordinal, room_update.room_sequence,
               room_update.timeline_sequence
        FROM input
        JOIN room_update ON room_update.room_id = input.room_id
        JOIN admission_gate ON admission_gate.room_id = input.room_id
        JOIN message_insert ON message_insert.message_id = input.message_id
        ORDER BY input.ordinal
        """

    typealias Row = FastPlainDirectRoomLogAllocationRow

    let inputs: [FastPlainDirectRoomLogAppendInput]
    let maximumStrangerMessages: Int64

    init(
        inputs: [FastPlainDirectRoomLogAppendInput],
        maximumStrangerMessages: Int
    ) {
        self.inputs = inputs
        self.maximumStrangerMessages = Int64(maximumStrangerMessages)
    }

    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 23)
        bindings.append(inputs.map(\.roomID))
        bindings.append(inputs.map(\.senderID))
        bindings.append(inputs.map(\.recipientID))
        bindings.append(inputs.map(\.messageID))
        bindings.append(inputs.map(\.eventID))
        bindings.append(inputs.map(\.clientMessageID))
        bindings.append(inputs.map(\.expectedMembershipRevision))
        bindings.append(inputs.map(\.expectedDirectPairRevision))
        bindings.append(inputs.map(\.expectedSenderPolicyRevision))
        bindings.append(inputs.map(\.expectedRecipientPolicyRevision))
        bindings.append(inputs.map(\.roomShardID))
        bindings.append(inputs.map(\.capacityProfileID))
        bindings.append(inputs.map(\.expectedShardLeaseID))
        bindings.append(inputs.map(\.expectedShardGeneration))
        bindings.append(inputs.map(\.requiresStrangerQuota))
        bindings.append(inputs.map(\.usesRoomAdmissionCredits))
        bindings.append(inputs.map(\.text))
        bindings.append(inputs.map(\.entitiesJSON))
        bindings.append(inputs.map(\.createdAtPostgresMicroseconds))
        bindings.append(inputs.map(\.windowStart))
        bindings.append(maximumStrangerMessages)
        bindings.append(inputs.map { Int16($0.fingerprint.version) })
        bindings.append(inputs.map { ByteBuffer(bytes: $0.fingerprint.digest) })
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> Row {
        let (ordinal, roomSequence, timelineSequence) = try row.decode(
            (Int32, Int64, Int64).self
        )
        return .init(
            ordinal: Int(ordinal),
            roomSequence: roomSequence,
            timelineSequence: timelineSequence
        )
    }
}

struct FastPlainDirectRoomLogAllocationRow: Decodable {
    let ordinal: Int
    let roomSequence: Int64
    let timelineSequence: Int64

    enum CodingKeys: String, CodingKey {
        case ordinal
        case roomSequence = "room_sequence"
        case timelineSequence = "timeline_sequence"
    }
}
