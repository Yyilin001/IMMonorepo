import Fluent
import Foundation
import IMV2Core
import SQLKit

public struct V2UserProjectionWorkerReport: Equatable, Sendable {
    public let claimed: Bool
    public let appliedRecordCount: Int
    public let failedRecordCount: Int
    public let pausedUserCount: Int

    public init(
        claimed: Bool,
        appliedRecordCount: Int,
        failedRecordCount: Int = 0,
        pausedUserCount: Int = 0
    ) {
        self.claimed = claimed
        self.appliedRecordCount = appliedRecordCount
        self.failedRecordCount = failedRecordCount
        self.pausedUserCount = pausedUserCount
    }
}

/// 把有界且连续的同步日志批次折叠为规范当前快照条目。
///
/// 整个短事务期间都会锁定检查点行，因此多个网关进程可以安全地并发运行该工作器。
public struct PostgresV2UserProjectionWorker: Sendable {
    private let database: any Database
    private let schema: String
    private let batchSize: Int
    private let retryPolicy: V2DurableRetryPolicy
    private let messageWriteMode: V2MessageProjectionWriteMode
    private let acceptedMessageBatchEnabled: Bool

    public init(
        database: any Database,
        schema: String = "im_v2",
        batchSize: Int = 100,
        retryPolicy: V2DurableRetryPolicy = .standard,
        messageWriteMode: V2MessageProjectionWriteMode = .dual,
        acceptedMessageBatchEnabled: Bool = true
    ) {
        precondition(batchSize > 0)
        precondition(schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil)
        self.database = database
        self.schema = schema
        self.batchSize = batchSize
        self.retryPolicy = retryPolicy
        self.messageWriteMode = messageWriteMode
        self.acceptedMessageBatchEnabled = acceptedMessageBatchEnabled
    }

    public func runOnce(now: Date = Date()) async throws -> V2UserProjectionWorkerReport {
        try Task.checkCancellation()
        guard v2PostgresTimestampCanEncode(now) else { throw V2UserProjectionWorkerError.corruptPersistence }
        do {
            return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2UserProjectionWorkerError.corruptPersistence
            }
            guard let checkpoint = try await sql.raw("""
                SELECT checkpoint.user_id, checkpoint.projected_sequence
                FROM \(unsafeRaw: table("user_projection_ready")) AS ready
                JOIN \(unsafeRaw: table("user_projection_checkpoints")) AS checkpoint
                  ON checkpoint.user_id = ready.user_id
                JOIN \(unsafeRaw: table("user_sync_sequences")) AS sequence
                  ON sequence.user_id = checkpoint.user_id
                WHERE ready.available_at <= \(bind: now)
                  AND checkpoint.projected_sequence < sequence.next_sequence
                  AND checkpoint.state = 'ready'
                  AND (checkpoint.next_attempt_at IS NULL OR checkpoint.next_attempt_at <= \(bind: now))
                  AND (checkpoint.migration_fence_expires_at IS NULL
                       OR checkpoint.migration_fence_expires_at <= now())
                ORDER BY ready.available_at, ready.enqueued_at, ready.user_id
                FOR UPDATE OF ready, checkpoint SKIP LOCKED
                LIMIT 1
                """).first(decoding: ProjectionCheckpointRow.self) else {
                return .init(claimed: false, appliedRecordCount: 0)
            }
            let rows = try await sql.raw("""
                SELECT log.user_sync_sequence, log.source_event_id, log.projection_kind,
                       CASE WHEN log.payload_storage = 'inline' THEN log.payload
                            ELSE COALESCE(shared.payload, state.payload) END::text AS payload_json,
                       CASE WHEN log.payload_storage = 'inline' THEN NULL ELSE shared.message_state_id END AS message_state_id,
                       state.message_id AS state_message_id,
                       state.room_id AS state_room_id,
                       state.message_revision AS state_message_revision,
                       state.variant_key AS state_variant_key,
                       state.payload_schema_version AS state_payload_schema_version,
                       state.origin_event_id AS state_origin_event_id,
                       state.state_event_id AS state_event_id,
                       state.is_withdrawn AS state_is_withdrawn,
                       state.payload->>'event_type' AS state_event_type,
                       state.payload->>'message_id' AS state_message_entity_key,
                       log.created_at
                FROM \(unsafeRaw: table("user_sync_log")) AS log
                LEFT JOIN \(unsafeRaw: table("fanout_sync_payloads")) AS shared
                  ON shared.source_event_id = log.source_event_id
                 AND shared.projection_kind = log.projection_kind
                LEFT JOIN \(unsafeRaw: table("message_projection_state_values")) AS state
                  ON state.state_id = shared.message_state_id
                WHERE log.user_id = \(bind: checkpoint.userID)
                  AND log.user_sync_sequence > \(bind: checkpoint.projectedSequence)
                ORDER BY log.user_sync_sequence
                LIMIT \(bind: batchSize)
                """).all(decoding: ProjectionSyncRow.self)
            guard !rows.isEmpty else { throw V2UserProjectionWorkerError.corruptPersistence }
            guard checkpoint.projectedSequence >= 0 else { throw V2UserProjectionWorkerError.corruptPersistence }
            var lastApplied = checkpoint.projectedSequence
            var rowIndex = 0
            while rowIndex < rows.count {
                if acceptedMessageBatchEnabled,
                   let firstInput = acceptedMessageBatchInput(rows[rowIndex]) {
                    var batch = [firstInput]
                    var nextIndex = rowIndex + 1
                    while nextIndex < rows.count,
                          let input = acceptedMessageBatchInput(rows[nextIndex]) {
                        batch.append(input)
                        nextIndex += 1
                    }
                    var batchLast = lastApplied
                    for input in batch {
                        guard batchLast < Int64.max, input.sequence == batchLast + 1
                        else { throw V2UserProjectionWorkerError.corruptPersistence }
                        batchLast = input.sequence
                    }
                    do {
                        try await applyAcceptedMessageBatch(
                            batch, userID: checkpoint.userID, sql: sql
                        )
                    } catch V2UserProjectionWorkerError.invalidPayload {
                        throw ProjectionApplyFailure(
                            userID: checkpoint.userID,
                            expectedCheckpoint: checkpoint.projectedSequence,
                            failedSequence: firstInput.sequence,
                            sourceEventID: firstInput.sourceEventID,
                            code: "invalid_payload"
                        )
                    }
                    lastApplied = batchLast
                    rowIndex = nextIndex
                    continue
                }
                let row = rows[rowIndex]
                try Task.checkCancellation()
                guard lastApplied < Int64.max, row.sequence == lastApplied + 1 else {
                    throw V2UserProjectionWorkerError.corruptPersistence
                }
                guard let payloadJSON = row.payloadJSON,
                      let payload = payloadJSON.data(using: .utf8)
                else {
                    throw ProjectionApplyFailure(
                        userID: checkpoint.userID,
                        expectedCheckpoint: checkpoint.projectedSequence,
                        failedSequence: row.sequence,
                        sourceEventID: row.sourceEventID,
                        code: "missing_payload"
                    )
                }
                do {
                    try await apply(
                        record: .init(sequence: UInt64(row.sequence), sourceEventID: .init(row.sourceEventID.uuidString), projectionKind: row.projectionKind, payload: payload),
                        messageStateID: row.messageStateID,
                        userID: checkpoint.userID, createdAt: row.createdAt, sql: sql
                    )
                } catch V2UserProjectionWorkerError.invalidPayload {
                    throw ProjectionApplyFailure(
                        userID: checkpoint.userID,
                        expectedCheckpoint: checkpoint.projectedSequence,
                        failedSequence: row.sequence,
                        sourceEventID: row.sourceEventID,
                        code: "invalid_payload"
                    )
                } catch is V2SnapshotProjectionV3Error {
                    throw ProjectionApplyFailure(
                        userID: checkpoint.userID,
                        expectedCheckpoint: checkpoint.projectedSequence,
                        failedSequence: row.sequence,
                        sourceEventID: row.sourceEventID,
                        code: "invalid_projection_key"
                    )
                }
                lastApplied = row.sequence
                rowIndex += 1
            }
            try await sql.raw("""
                WITH locked_sequence AS MATERIALIZED (
                    -- Delivery reserves this same row before its Sync Log
                    -- insert. Lock it before deciding whether the durable
                    -- ready row is obsolete, so a concurrent v6 enqueue is
                    -- ordered either wholly before or wholly after removal.
                    SELECT user_id, next_sequence
                    FROM \(unsafeRaw: table("user_sync_sequences"))
                    WHERE user_id = \(bind: checkpoint.userID)
                    FOR UPDATE
                ), advanced AS (
                    UPDATE \(unsafeRaw: table("user_projection_checkpoints"))
                    SET projected_sequence = \(bind: lastApplied), state = 'ready',
                        failure_count = 0, failed_sequence = NULL,
                        next_attempt_at = NULL, last_failure_code = NULL,
                        paused_at = NULL, updated_at = \(bind: now)
                    WHERE user_id = \(bind: checkpoint.userID)
                    RETURNING user_id, projected_sequence
                ), removed_if_caught_up AS (
                    DELETE FROM \(unsafeRaw: table("user_projection_ready")) AS ready
                    USING advanced, locked_sequence AS sequence
                    WHERE ready.user_id = advanced.user_id
                      AND sequence.user_id = advanced.user_id
                      AND sequence.next_sequence <= advanced.projected_sequence
                    RETURNING ready.user_id
                )
                UPDATE \(unsafeRaw: table("user_projection_ready")) AS ready
                SET available_at = \(bind: now), updated_at = \(bind: now)
                FROM advanced, locked_sequence AS sequence
                WHERE ready.user_id = advanced.user_id
                  AND sequence.user_id = advanced.user_id
                  AND sequence.next_sequence > advanced.projected_sequence
                """).run()
            return .init(claimed: true, appliedRecordCount: rows.count)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as ProjectionApplyFailure {
            return try await recordFailure(failure, now: now)
        }
    }

    /// 仅在状态符合 `PostgresV2MessageProjectionStateRepository` 产出的不可变修订 1 形态时，
    /// 返回类型化的快速路径输入。
    ///
    /// 完整的载荷校验属于那个唯一的状态创建边界；这条按接收者展开的路径只复核身份、修订、
    /// 房间、事件与确定性状态标识，避免为每个用户重复解码同一份正文。
    /// 其余情况一律刻意回落到既有状态机。
    ///
    /// - Parameter row: 待判定的投影同步行。
    /// - Returns: 可走批量快速路径的输入；不满足条件时返回 `nil`。
    private func acceptedMessageBatchInput(
        _ row: ProjectionSyncRow
    ) -> AcceptedMessageProjectionBatchInput? {
        guard row.projectionKind == "message",
              let stateID = row.messageStateID,
              let messageID = row.stateMessageID,
              let roomID = row.stateRoomID,
              row.stateMessageRevision == 1,
              row.stateVariantKey == 0,
              row.statePayloadSchemaVersion == 1,
              row.stateOriginEventID == row.sourceEventID,
              row.stateEventID == row.sourceEventID,
              row.stateIsWithdrawn == false,
              row.stateEventType == "message.accepted",
              let entityKey = row.stateMessageEntityKey,
              UUID(uuidString: entityKey) == messageID,
              (try? v2MessageProjectionStateID(
                  messageID: messageID, messageRevision: 1
              )) == stateID
        else { return nil }
        // The scalar bind and batch SQL both preserve the exact database
        // offset. Decoding through Date would lose valid microseconds.
        return .init(
            sequence: row.sequence,
            sourceEventID: row.sourceEventID,
            messageStateID: stateID,
            messageID: messageID,
            // Preserve the established projection-key representation from
            // the already-validated immutable payload. UUID comparison is
            // case-insensitive, but changing representation only on the fast
            // path would make batch on/off produce different snapshots.
            entityKey: entityKey,
            roomID: roomID,
            createdAtPostgresMicroseconds: row.createdAt.microseconds
        )
    }

    /// 在一次 PostgreSQL 往返内关闭并插入一段相互独立的已接受消息版本。
    ///
    /// 最终计数是一道完整性栅栏：只要出现一个非法状态就抛出，并把整个外层检查点事务回滚，
    /// 与逐条实现的语义完全一致。
    ///
    /// - Parameters:
    ///   - inputs: 本批快速路径输入。
    ///   - userID: 目标用户。
    ///   - sql: 当前事务使用的数据库连接。
    /// - Throws: 任一状态非法或持久化失败时抛出。
    private func applyAcceptedMessageBatch(
        _ inputs: [AcceptedMessageProjectionBatchInput],
        userID: UUID,
        sql: any SQLDatabase
    ) async throws {
        guard !inputs.isEmpty,
              let inputJSON = String(data: try JSONEncoder().encode(inputs), encoding: .utf8)
        else { throw V2UserProjectionWorkerError.invalidPayload }
        let writesInlinePayload = messageWriteMode != .shared
        let writesStateReference = messageWriteMode != .inline
        guard let result = try await sql.raw("""
            WITH input AS MATERIALIZED (
                SELECT value.sequence, value.source_event_id, value.message_state_id,
                       value.message_id, value.entity_key, value.room_id,
                       value.created_at_postgres_microseconds
                FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb) AS value(
                    sequence bigint, source_event_id uuid, message_state_id uuid,
                    message_id uuid, entity_key text, room_id uuid,
                    created_at_postgres_microseconds bigint
                )
            ), validated AS MATERIALIZED (
                SELECT input.sequence, input.source_event_id, input.message_state_id,
                       input.message_id, input.entity_key, input.created_at_postgres_microseconds,
                       state.room_id, state.origin_event_id, state.payload,
                       (current.source_event_id IS NOT NULL) AS has_current
                FROM input
                JOIN \(unsafeRaw: table("message_projection_state_values")) AS state
                  ON state.state_id = input.message_state_id
                 AND state.state_event_id = input.source_event_id
                 AND state.message_id = input.message_id
                 AND lower(input.entity_key) = input.message_id::text
                 AND state.room_id = input.room_id
                 AND state.message_revision = 1
                 AND state.variant_key = 0
                 AND state.payload_schema_version = 1
                 AND state.origin_event_id = state.state_event_id
                 AND state.is_withdrawn = FALSE
                 AND state.payload->>'event_type' = 'message.accepted'
                 AND lower(state.payload->>'message_id') = state.message_id::text
                 AND lower(state.payload->>'room_id') = state.room_id::text
                 AND state.payload->>'message_revision' = '1'
                LEFT JOIN LATERAL (
                    SELECT version.source_event_id,
                           COALESCE(current_state.payload, version.payload) AS payload
                    FROM \(unsafeRaw: table("user_projection_versions")) AS version
                    LEFT JOIN \(unsafeRaw: table("message_projection_state_values")) AS current_state
                      ON current_state.state_id = version.message_state_id
                    WHERE version.user_id = \(bind: userID)
                      AND version.projection_kind = 'message'
                      AND version.entity_key = input.entity_key
                      AND version.valid_to_sequence IS NULL
                ) AS current ON TRUE
                WHERE current.source_event_id IS NULL OR (
                    current.source_event_id = state.origin_event_id
                    AND lower(current.payload->>'message_id') = state.message_id::text
                    AND lower(current.payload->>'room_id') = state.room_id::text
                    AND current.payload->>'room_sequence' = state.payload->>'room_sequence'
                    AND COALESCE(current.payload->>'timeline_sequence', current.payload->>'room_sequence') = state.payload->>'timeline_sequence'
                    AND lower(current.payload->>'sender_user_id') = lower(state.payload->>'sender_user_id')
                    AND current.payload->>'server_created_at_ms' = state.payload->>'server_created_at_ms'
                    AND ((current.payload->>'message_revision')::bigint > 1 OR current.payload = state.payload)
                )
            ), closed AS (
                UPDATE \(unsafeRaw: table("user_projection_versions")) AS version
                SET valid_to_sequence = validated.sequence
                FROM validated
                WHERE version.user_id = \(bind: userID)
                  AND version.projection_kind = 'message'
                  AND version.entity_key = validated.entity_key
                  AND version.valid_to_sequence IS NULL
                  AND NOT validated.has_current
                RETURNING 1
            ), inserted AS (
                INSERT INTO \(unsafeRaw: table("user_projection_versions"))
                    (user_id, projection_kind, entity_key, scope_room_id,
                     valid_from_sequence, valid_to_sequence, source_event_id,
                     payload, message_state_id, created_at)
                SELECT \(bind: userID), 'message', validated.entity_key,
                       validated.room_id, validated.sequence, NULL,
                       validated.origin_event_id,
                       CASE WHEN \(bind: writesInlinePayload) THEN validated.payload ELSE NULL END,
                       CASE WHEN \(bind: writesStateReference)
                            THEN validated.message_state_id ELSE NULL END,
                       (TIMESTAMP '2000-01-01 00:00:00'
                         + (validated.created_at_postgres_microseconds / 86400000000)
                           * INTERVAL '1 day'
                         + (validated.created_at_postgres_microseconds % 86400000000)
                           * INTERVAL '1 microsecond') AT TIME ZONE 'UTC'
                FROM validated
                WHERE NOT validated.has_current
                ORDER BY validated.sequence
                RETURNING 1
            )
            SELECT (SELECT COUNT(*) FROM inserted) + (SELECT COUNT(*) FROM validated WHERE has_current) AS inserted_count
            """).first(decoding: ProjectionBatchCountRow.self),
              result.insertedCount == inputs.count
        else { throw V2UserProjectionWorkerError.invalidPayload }
    }

    private func recordFailure(
        _ failure: ProjectionApplyFailure,
        now: Date
    ) async throws -> V2UserProjectionWorkerReport {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase,
                  let checkpoint = try await sql.raw("""
                    SELECT failure_count
                    FROM \(unsafeRaw: table("user_projection_checkpoints"))
                    WHERE user_id = \(bind: failure.userID)
                      AND projected_sequence = \(bind: failure.expectedCheckpoint)
                      AND state = 'ready'
                    FOR UPDATE
                    """).first(decoding: ProjectionFailureCountRow.self)
            else {
                // Another worker advanced or paused this user after our
                // transaction rolled back. The failed claim is still useful
                // work, but must not overwrite the newer checkpoint state.
                return .init(claimed: true, appliedRecordCount: 0)
            }
            guard checkpoint.failureCount < Int64.max else {
                throw V2UserProjectionWorkerError.corruptPersistence
            }
            let attempt = Int(clamping: checkpoint.failureCount + 1)
            switch retryPolicy.disposition(
                attempt: attempt,
                claimToken: failure.sourceEventID,
                now: now
            ) {
            case .retry(let nextAttemptAt):
                guard v2PostgresFutureTimestamp(now: now, interval: nextAttemptAt.timeIntervalSince(now)) != nil else {
                    throw V2UserProjectionWorkerError.corruptPersistence
                }
                try await sql.raw("""
                    UPDATE \(unsafeRaw: table("user_projection_checkpoints"))
                    SET failure_count = \(bind: attempt),
                        failed_sequence = \(bind: failure.failedSequence),
                        next_attempt_at = \(bind: nextAttemptAt),
                        last_failure_code = \(bind: failure.code),
                        updated_at = \(bind: now)
                    WHERE user_id = \(bind: failure.userID)
                    """).run()
                try await sql.raw("""
                    INSERT INTO \(unsafeRaw: table("user_projection_ready"))
                        (user_id, available_at, enqueued_at, updated_at)
                    VALUES (\(bind: failure.userID), \(bind: nextAttemptAt),
                            \(bind: now), \(bind: now))
                    ON CONFLICT (user_id) DO UPDATE
                    SET available_at = EXCLUDED.available_at,
                        updated_at = EXCLUDED.updated_at
                    """).run()
                return .init(claimed: true, appliedRecordCount: 0, failedRecordCount: 1)
            case .pause:
                try await sql.raw("""
                    UPDATE \(unsafeRaw: table("user_projection_checkpoints"))
                    SET state = 'paused', failure_count = \(bind: attempt),
                        failed_sequence = \(bind: failure.failedSequence),
                        next_attempt_at = NULL,
                        last_failure_code = \(bind: failure.code),
                        paused_at = \(bind: now), updated_at = \(bind: now)
                    WHERE user_id = \(bind: failure.userID)
                    """).run()
                try await sql.raw("""
                    DELETE FROM \(unsafeRaw: table("user_projection_ready"))
                    WHERE user_id = \(bind: failure.userID)
                    """).run()
                return .init(
                    claimed: true,
                    appliedRecordCount: 0,
                    failedRecordCount: 1,
                    pausedUserCount: 1
                )
            }
        }
    }

    private func apply(
        record: V2ClientLikeRecord,
        messageStateID: UUID?,
        userID: UUID,
        createdAt: V2PostgresTimestamp,
        sql: any SQLDatabase
    ) async throws {
        let payload: Any
        do {
            payload = try JSONSerialization.jsonObject(with: record.payload)
        } catch {
            throw V2UserProjectionWorkerError.invalidPayload
        }
        guard let object = payload as? [String: Any] else { throw V2UserProjectionWorkerError.invalidPayload }
        let eventType = object["event_type"] as? String
        let key: V2SnapshotProjectionKey
        switch record.projectionKind {
        case "message":
            key = try projectionKey("message", string("message_id", object))
            try await applyMessage(
                record: record,
                object: object,
                eventType: eventType,
                messageStateID: messageStateID,
                userID: userID,
                createdAt: createdAt,
                key: key,
                sql: sql
            )
            return
        case "message_reaction":
            guard eventType == "message.reaction_changed" else {
                throw V2UserProjectionWorkerError.invalidPayload
            }
            let messageID = try string("message_id", object)
            let actorUserID = try string("actor_user_id", object)
            let reaction = try string("reaction", object)
            guard UUID(uuidString: messageID) != nil,
                  UUID(uuidString: actorUserID) != nil,
                  reaction.utf8.count <= V2MessageReactionLimits.maximumReactionBytes
            else { throw V2UserProjectionWorkerError.invalidPayload }
            key = try projectionKey("message_reaction", "\(messageID):\(actorUserID):\(reaction)")
            let incoming = try JSONDecoder().decode(ReactionSnapshotOrder.self, from: record.payload)
            guard incoming.roomSequence > 0, incoming.action == "add" || incoming.action == "remove" else { throw V2UserProjectionWorkerError.invalidPayload }
            let withdrawn = try await sql.raw("""
                SELECT EXISTS (
                    SELECT 1 FROM \(unsafeRaw: table("user_projection_versions")) AS message
                    LEFT JOIN \(unsafeRaw: table("message_projection_state_values")) AS state ON state.state_id = message.message_state_id
                    WHERE message.user_id = \(bind: userID) AND message.projection_kind = 'message'
                      AND message.entity_key IN (\(bind: incoming.messageID.uuidString), \(bind: incoming.messageID.uuidString.lowercased()))
                      AND message.scope_room_id = \(bind: incoming.roomID) AND message.valid_to_sequence IS NULL
                      AND COALESCE((COALESCE(state.payload, message.payload)->>'is_withdrawn')::boolean, FALSE)
                ) AS withdrawn
                """).first(decoding: ReactionMessageWithdrawal.self)?.withdrawn == true
            if withdrawn {
                try await remove(key: key, at: record.sequence, userID: userID, sql: sql)
                return
            }
            if let current = try await sql.raw("""
                SELECT payload::text AS payload_json, source_event_id
                FROM \(unsafeRaw: table("user_projection_versions"))
                WHERE user_id = \(bind: userID) AND projection_kind = 'message_reaction'
                  AND entity_key = \(bind: key.entityKey) AND valid_to_sequence IS NULL
                """).first(decoding: ProjectionPayloadRow.self) {
                let prior = try JSONDecoder().decode(ReactionSnapshotOrder.self, from: Data(current.payloadJSON.utf8))
                guard prior.roomID == incoming.roomID else { throw V2UserProjectionWorkerError.invalidPayload }
                if prior.roomSequence > incoming.roomSequence { return }
                if prior.roomSequence == incoming.roomSequence {
                    guard prior == incoming, current.sourceEventID == record.sourceEventID.uuidValue else { throw V2UserProjectionWorkerError.invalidPayload }
                    return
                }
            }
            // Keep negative state in the current snapshot; absence alone
            // cannot fence an older addition from another delivery stream.
            try await replace(key: key, record: record, payload: record.payload, userID: userID, createdAt: createdAt, sql: sql)
            return
        case "room": key = try projectionKey("room", string("room_id", object))
        case "membership":
            try await applyMembership(record: record, object: object, userID: userID, createdAt: createdAt, sql: sql)
            return
        case "moderation" where eventType == "room.frozen" || eventType == "room.unfrozen": key = try projectionKey("moderation", string("room_id", object))
        case "moderation": key = try projectionKey("moderation", "\(try string("room_id", object)):\(try string("target_user_id", object))")
        case "relationship": key = try projectionKey("relationship", string("target_user_id", object))
        case "user_block": key = try projectionKey("user_block", string("target_user_id", object))
        case "stranger_message_permission", "user_add_permission", "read_receipt_preferences": key = try projectionKey(record.projectionKind, "singleton")
        case "direct_room_profile", "direct_read_receipt", "conversation_state", "direct_sending_capability": key = try projectionKey(record.projectionKind, string("room_id", object))
        case "message_favorite": key = try projectionKey(record.projectionKind, string("message_id", object))
        case "timeline_activity": key = try projectionKey(record.projectionKind, record.sourceEventID.rawValue)
        case "profile_invalidation": key = try projectionKey(record.projectionKind, string("user_id", object))
        case "group_capability" where eventType == "message.pinned_changed":
            try await applyPinnedMessage(record: record, userID: userID, createdAt: createdAt, sql: sql)
            return
        case "group_capability" where eventType == "group.announcement_changed" || eventType == "group.role_permissions_changed" || eventType == "group.member_role_changed":
            try await applyGroupPolicy(record: record, userID: userID, createdAt: createdAt, sql: sql)
            return
        case "group_capability":
            key = try groupCapabilityKey(eventType: eventType, object: object)
        default: throw V2UserProjectionWorkerError.invalidPayload
        }
        if try representsAbsence(record: record, object: object, eventType: eventType) {
            try await remove(key: key, at: record.sequence, userID: userID, sql: sql)
            return
        }
        try await replace(key: key, record: record, payload: record.payload, userID: userID, createdAt: createdAt, sql: sql)
    }

    private func applyPinnedMessage(
        record: V2ClientLikeRecord,
        userID: UUID,
        createdAt: V2PostgresTimestamp,
        sql: any SQLDatabase
    ) async throws {
        let incoming = try V2PinnedMessageSnapshotEffect(payload: record.payload)
        guard let sourceEventID = record.sourceEventID.uuidValue else {
            throw V2UserProjectionWorkerError.invalidPayload
        }
        var key = try projectionKey("group_capability", incoming.entityKey)
        let lowercaseRoomKey = "pin:\(incoming.roomID.uuidString.lowercased()):\(incoming.messageID.uuidString)"
        let lowercaseMessageKey = "pin:\(incoming.roomID.uuidString):\(incoming.messageID.uuidString.lowercased())"
        let current = try await sql.raw("""
            SELECT entity_key, payload::text AS payload_json, source_event_id
            FROM \(unsafeRaw: table("user_projection_versions"))
            WHERE user_id = \(bind: userID) AND projection_kind = 'group_capability'
              AND entity_key IN (\(bind: key.entityKey), \(bind: key.entityKey.lowercased()),
                                 \(bind: lowercaseRoomKey), \(bind: lowercaseMessageKey))
              AND valid_to_sequence IS NULL
            """).all(decoding: GroupPolicyProjectionPayloadRow.self)
        guard current.count <= 1 else { throw V2UserProjectionWorkerError.invalidPayload }
        if let prior = current.first {
            guard try incoming.shouldReplace(
                V2PinnedMessageSnapshotEffect(payload: Data(prior.payloadJSON.utf8)),
                sourceEventID: sourceEventID,
                priorSourceEventID: prior.sourceEventID
            ) else { return }
            key = try projectionKey("group_capability", prior.entityKey)
        }
        // Unpin is a current negative fact. Deleting it would let an older pin
        // become current after replay or appear in a newly built snapshot.
        try await replace(key: key, record: record, payload: record.payload, userID: userID, createdAt: createdAt, sql: sql)
    }

    private func applyGroupPolicy(
        record: V2ClientLikeRecord,
        userID: UUID,
        createdAt: V2PostgresTimestamp,
        sql: any SQLDatabase
    ) async throws {
        let incoming = try V2GroupPolicySnapshotEffect(payload: record.payload)
        var key = try projectionKey("group_capability", incoming.entityKey)
        let lowercaseRoomKey: String
        let lowercaseTargetKey: String
        if case .memberRole(let target, _, _) = incoming.value {
            lowercaseRoomKey = "member-role:\(incoming.roomID.uuidString.lowercased()):\(target.uuidString)"
            lowercaseTargetKey = "member-role:\(incoming.roomID.uuidString):\(target.uuidString.lowercased())"
        } else {
            lowercaseRoomKey = key.entityKey
            lowercaseTargetKey = key.entityKey
        }
        // Canonical UUID spelling must not create a second logical object for
        // a retained older snapshot key using lowercase PostgreSQL UUID text.
        let current = try await sql.raw("""
            SELECT entity_key, payload::text AS payload_json, source_event_id
            FROM \(unsafeRaw: table("user_projection_versions"))
            WHERE user_id = \(bind: userID) AND projection_kind = 'group_capability'
              AND entity_key IN (\(bind: key.entityKey), \(bind: key.entityKey.lowercased()),
                                 \(bind: lowercaseRoomKey), \(bind: lowercaseTargetKey))
              AND valid_to_sequence IS NULL
            """).all(decoding: GroupPolicyProjectionPayloadRow.self)
        guard current.count <= 1 else { throw V2UserProjectionWorkerError.invalidPayload }
        if let prior = current.first {
            let priorEffect = try V2GroupPolicySnapshotEffect(payload: Data(prior.payloadJSON.utf8))
            guard priorEffect.entityKey == incoming.entityKey else { throw V2UserProjectionWorkerError.invalidPayload }
            if prior.sourceEventID == record.sourceEventID.uuidValue {
                guard priorEffect.representsSameFact(as: incoming) else { throw V2UserProjectionWorkerError.invalidPayload }
                return
            }
            if priorEffect.revision > incoming.revision { return }
            if priorEffect.revision == incoming.revision {
                throw V2UserProjectionWorkerError.invalidPayload
            }
            key = try projectionKey("group_capability", prior.entityKey)
        }
        // Keep explicit empty state. It is an authoritative version, not a
        // request to erase the object's ordering fence from future snapshots.
        try await replace(key: key, record: record, payload: record.payload, userID: userID, createdAt: createdAt, sql: sql)
    }

    private func applyMembership(
        record: V2ClientLikeRecord,
        object: [String: Any],
        userID: UUID,
        createdAt: V2PostgresTimestamp,
        sql: any SQLDatabase
    ) async throws {
        guard object["event_type"] as? String == "membership_changed" else {
            throw V2UserProjectionWorkerError.invalidPayload
        }
        let roomValue = try string("room_id", object)
        let targetValue = try string("target_user_id", object)
        guard let roomID = UUID(uuidString: roomValue),
              let targetUserID = UUID(uuidString: targetValue)
        else { throw V2UserProjectionWorkerError.invalidPayload }
        let action = try string("action", object)
        guard action == "add" || action == "remove" else {
            throw V2UserProjectionWorkerError.invalidPayload
        }
        if action == "remove" {
            // Member-role state is no longer current for any recipient.
            try await remove(
                key: projectionKey("group_capability", "member-role:\(roomValue):\(targetValue)"),
                at: record.sequence,
                userID: userID,
                sql: sql
            )
            if targetUserID == userID {
                // A reset must not resurrect any room-scoped value after this
                // user loses membership. `scope_room_id` makes this one
                // indexed database update, regardless of room history size.
                try await removeRoomScope(roomID: roomID, at: record.sequence, userID: userID, sql: sql)
                return
            }
        }
        try await replace(
            key: projectionKey("room", roomValue),
            record: record,
            payload: record.payload,
            userID: userID,
            createdAt: createdAt,
            sql: sql
        )
    }

    private func representsAbsence(
        record: V2ClientLikeRecord,
        object: [String: Any],
        eventType: String?
    ) throws -> Bool {
        switch record.projectionKind {
        case "relationship": return try string("state", object) == "none"
        case "user_block": return try boolean("is_blocked", object) == false
        case "direct_read_receipt": return try boolean("is_visible", object) == false
        case "message_favorite": return try boolean("is_favorited", object) == false
        case "conversation_state":
            let mute = object["mute_until_ms"] as? NSNumber
            return try boolean("is_pinned", object) == false
                && boolean("is_archived", object) == false
                && (mute?.int64Value ?? 0) == 0
        case "moderation" where eventType == "room.unfrozen": return true
        default: return false
        }
    }

    private func applyMessage(
        record: V2ClientLikeRecord,
        object: [String: Any],
        eventType: String?,
        messageStateID: UUID?,
        userID: UUID,
        createdAt: V2PostgresTimestamp,
        key: V2SnapshotProjectionKey,
        sql: any SQLDatabase
    ) async throws {
        var effectiveStateID = messageStateID
        if effectiveStateID == nil, eventType == "message.withdrawn" || eventType == "message.redacted" {
            let identity = try messageVersionIdentity(record.payload)
            guard identity.messageRevision > 1 else { throw V2UserProjectionWorkerError.invalidPayload }
            // Inline compatibility records may still have an immutable state
            // copied with fanout. Never fetch a current owner body as fallback.
            effectiveStateID = try await PostgresV2MessageProjectionStateRepository(schema: schema)
                .load(messageID: identity.messageID, revision: identity.messageRevision, sql: sql)?.stateID
        }
        if let messageStateID = effectiveStateID {
            do {
                try await applySharedMessage(
                    record: record,
                    object: object,
                    eventType: eventType,
                    messageStateID: messageStateID,
                    userID: userID,
                    createdAt: createdAt,
                    key: key,
                    sql: sql
                )
                return
            } catch is V2MessageProjectionStateError {
                throw V2UserProjectionWorkerError.invalidPayload
            } catch is V2MessageProjectionStatePersistenceError {
                throw V2UserProjectionWorkerError.invalidPayload
            }
        }
        switch eventType {
        case "message.accepted":
            if try await currentObjectIfPresent(key: key, userID: userID, sql: sql) != nil {
                do {
                    let state = try V2MessageProjectionState(payloadJSON: String(decoding: record.payload, as: UTF8.self))
                    guard let origin = UUID(uuidString: record.sourceEventID.rawValue) else { throw V2UserProjectionWorkerError.invalidPayload }
                    guard try await shouldInstallMessageState(state, origin: origin, key: key, userID: userID, sql: sql) else { return }
                } catch { throw V2UserProjectionWorkerError.invalidPayload }
            }
            try await replace(key: key, record: record, payload: record.payload, userID: userID, createdAt: createdAt, sql: sql)
        case "message.edited":
            if let replacement = try editReplacement(object) {
                guard try await shouldInstallReplacement(replacement, key: key, userID: userID, sql: sql) else { return }
                try await replace(key: key, record: record, payload: Data(replacement.state.encodedPayloadJSON().utf8), sourceEventID: replacement.acceptedEventID, userID: userID, createdAt: createdAt, sql: sql)
                return
            }
            let stored = try await currentObject(key: key, userID: userID, sql: sql)
            var current = stored.object
            let incoming = try messageVersionIdentity(record.payload)
            let previous = try messageVersionIdentity(jsonData(current))
            guard incoming.messageID == previous.messageID, incoming.roomID == previous.roomID,
                  incoming.messageRevision > 1, let text = object["text"] as? String, !text.isEmpty
            else { throw V2UserProjectionWorkerError.invalidPayload }
            let entities: [V2MessageEntity]
            do {
                entities = try JSONDecoder().decode([V2MessageEntity].self, from: jsonDataArray(object["entities"] ?? []))
                try V2RichMessageContent.validate(text: text, entities: entities)
            } catch { throw V2UserProjectionWorkerError.invalidPayload }
            if incoming.messageRevision < previous.messageRevision { return }
            guard current["is_withdrawn"] as? Bool != true else { throw V2UserProjectionWorkerError.invalidPayload }
            if incoming.messageRevision == previous.messageRevision {
                guard current["text"] as? String == text,
                      (try? JSONDecoder().decode([V2MessageEntity].self, from: jsonDataArray(current["entities"] ?? []))) == entities
                else { throw V2UserProjectionWorkerError.invalidPayload }
                return
            }
            guard previous.messageRevision < Int64.max, incoming.messageRevision == previous.messageRevision + 1
            else { throw V2UserProjectionWorkerError.invalidPayload }
            current["text"] = text
            current["entities"] = object["entities"] ?? []
            current["message_revision"] = object["message_revision"]
            try await replace(key: key, record: record, payload: try jsonData(current), sourceEventID: stored.sourceEventID, userID: userID, createdAt: createdAt, sql: sql)
        case "message.withdrawn", "message.redacted":
            let stored = try await currentObject(key: key, userID: userID, sql: sql)
            var current = stored.object
            let incoming = try messageVersionIdentity(record.payload)
            let previous = try messageVersionIdentity(jsonData(current))
            guard incoming.messageID == previous.messageID, incoming.roomID == previous.roomID,
                  incoming.messageRevision > 1
            else { throw V2UserProjectionWorkerError.invalidPayload }
            if incoming.messageRevision <= previous.messageRevision {
                guard hasRemovedContent(current) else { throw V2UserProjectionWorkerError.invalidPayload }
                try await removeMessageReactions(messageID: incoming.messageID.uuidString, at: record.sequence, userID: userID, sql: sql)
                return
            }
            guard current["is_withdrawn"] as? Bool != true else { throw V2UserProjectionWorkerError.invalidPayload }
            current["message_revision"] = incoming.messageRevision
            // A snapshot item is a self-contained current value, not the
            // latest delta. Keep the accepted envelope so a clean client can
            // reconstruct the row, but remove every content-bearing field
            // before this value becomes snapshot-visible.
            current["event_type"] = "message.accepted"
            current["is_withdrawn"] = true
            current["text"] = "[removed]"
            current["media_ids"] = []
            current["media_presentations"] = []
            current["mention_user_ids"] = []
            current["mentions_everyone"] = false
            current["entities"] = []
            current["reply_to_message_id"] = nil
            current["forwarded_from_message_id"] = nil
            current["forwarded_from_user_id"] = nil
            try await replace(key: key, record: record, payload: try jsonData(current), sourceEventID: stored.sourceEventID, userID: userID, createdAt: createdAt, sql: sql)
            try await removeMessageReactions(messageID: try string("message_id", object), at: record.sequence, userID: userID, sql: sql)
        default: throw V2UserProjectionWorkerError.invalidPayload
        }
    }

    private func applySharedMessage(
        record: V2ClientLikeRecord,
        object: [String: Any],
        eventType: String?,
        messageStateID: UUID,
        userID: UUID,
        createdAt: V2PostgresTimestamp,
        key: V2SnapshotProjectionKey,
        sql: any SQLDatabase
    ) async throws {
        let identity = try messageVersionIdentity(record.payload)
        guard let stored = try await PostgresV2MessageProjectionStateRepository(schema: schema)
            .load(stateID: messageStateID, sql: sql),
              stored.stateID == messageStateID,
              stored.messageID == identity.messageID, stored.roomID == identity.roomID,
              stored.messageRevision == identity.messageRevision,
              stored.stateEventID == UUID(uuidString: record.sourceEventID.rawValue),
              stored.messageID.uuidString.lowercased() == key.entityKey.lowercased(),
              let eventRevision = (object["message_revision"] as? NSNumber)?.int64Value,
              eventRevision == stored.messageRevision,
              eventRevision > 0
        else { throw V2UserProjectionWorkerError.invalidPayload }
        _ = try stored.state
        switch eventType {
        case "message.accepted":
            guard stored.messageRevision == 1,
                  stored.originEventID == stored.stateEventID,
                  !stored.isWithdrawn
            else { throw V2UserProjectionWorkerError.invalidPayload }
            guard try await shouldInstallMessageState(stored.state, origin: stored.originEventID, key: key, userID: userID, sql: sql) else { return }
        case "message.edited" where object["replacement"] != nil:
            guard let replacement = try editReplacement(object),
                  replacement.acceptedEventID == stored.originEventID,
                  replacement.state == (try stored.state)
            else { throw V2UserProjectionWorkerError.invalidPayload }
            guard try await shouldInstallReplacement(replacement, key: key, userID: userID, sql: sql) else { return }
        case "message.withdrawn", "message.redacted":
            guard stored.isWithdrawn, stored.messageRevision > 1 else { throw V2UserProjectionWorkerError.invalidPayload }
            // Ordinary withdrawal uses the accepted audience intersection.
            // Moderation still needs a separate bodyless historical revocation
            // contract; do not create a baseline for an unseen redaction.
            if eventType == "message.redacted" {
                _ = try await currentObject(key: key, userID: userID, sql: sql)
            }
            if try await !shouldInstallMessageState(stored.state, origin: stored.originEventID, key: key, userID: userID, sql: sql) {
                try await removeMessageReactions(messageID: identity.messageID.uuidString, at: record.sequence, userID: userID, sql: sql)
                return
            }
        case "message.edited":
            let current = try await currentObject(key: key, userID: userID, sql: sql)
            guard let currentRevision = (current.object["message_revision"] as? NSNumber)?.int64Value,
                  currentRevision < Int64.max,
                  currentRevision + 1 == stored.messageRevision,
                  current.sourceEventID == stored.originEventID,
                  stored.isWithdrawn == (eventType != "message.edited")
            else { throw V2UserProjectionWorkerError.invalidPayload }
        default:
            throw V2UserProjectionWorkerError.invalidPayload
        }
        try await replaceSharedMessage(
            key: key,
            record: record,
            stored: stored,
            userID: userID,
            createdAt: createdAt,
            sql: sql
        )
        if eventType == "message.withdrawn" || eventType == "message.redacted" {
            try await removeMessageReactions(
                messageID: try string("message_id", object),
                at: record.sequence,
                userID: userID,
                sql: sql
            )
        }
    }

    private func replaceSharedMessage(
        key: V2SnapshotProjectionKey,
        record: V2ClientLikeRecord,
        stored: V2StoredMessageProjectionState,
        userID: UUID,
        createdAt: V2PostgresTimestamp,
        sql: any SQLDatabase
    ) async throws {
        guard let sequence = Int64(exactly: record.sequence) else {
            throw V2UserProjectionWorkerError.invalidPayload
        }
        let inlinePayload: String?
        let stateReference: UUID?
        switch messageWriteMode {
        case .inline:
            inlinePayload = stored.payloadJSON
            stateReference = nil
        case .dual:
            inlinePayload = stored.payloadJSON
            stateReference = stored.stateID
        case .shared:
            inlinePayload = nil
            stateReference = stored.stateID
        }
        try await sql.raw("""
            UPDATE \(unsafeRaw: table("user_projection_versions"))
            SET valid_to_sequence = \(bind: sequence)
            WHERE user_id = \(bind: userID) AND projection_kind = 'message'
              AND entity_key = \(bind: key.entityKey) AND valid_to_sequence IS NULL
            """).run()
        try await sql.raw("""
            INSERT INTO \(unsafeRaw: table("user_projection_versions"))
                (user_id, projection_kind, entity_key, scope_room_id,
                 valid_from_sequence, valid_to_sequence, source_event_id,
                 payload, message_state_id, created_at)
            VALUES
                (\(bind: userID), 'message', \(bind: key.entityKey),
                 \(bind: stored.roomID), \(bind: sequence), NULL,
                 \(bind: stored.originEventID), \(bind: inlinePayload)::jsonb,
                 \(bind: stateReference), \(bind: createdAt))
            """).run()
    }

    private func replace(key: V2SnapshotProjectionKey, record: V2ClientLikeRecord, payload: Data, sourceEventID: UUID? = nil, userID: UUID, createdAt: V2PostgresTimestamp, sql: any SQLDatabase) async throws {
        guard let sequence = Int64(exactly: record.sequence), let payloadJSON = String(data: payload, encoding: .utf8), let source = sourceEventID ?? UUID(uuidString: record.sourceEventID.rawValue) else {
            throw V2UserProjectionWorkerError.invalidPayload
        }
        let roomID = try scopeRoomID(payload)
        try await sql.raw("""
            UPDATE \(unsafeRaw: table("user_projection_versions"))
            SET valid_to_sequence = \(bind: sequence)
            WHERE user_id = \(bind: userID) AND projection_kind = \(bind: key.projectionKind)
              AND entity_key = \(bind: key.entityKey) AND valid_to_sequence IS NULL
            """).run()
        try await sql.raw("""
            INSERT INTO \(unsafeRaw: table("user_projection_versions"))
                (user_id, projection_kind, entity_key, scope_room_id, valid_from_sequence,
                 valid_to_sequence, source_event_id, payload, created_at)
            VALUES (\(bind: userID), \(bind: key.projectionKind), \(bind: key.entityKey), \(bind: roomID),
                    \(bind: sequence), NULL, \(bind: source),
                    \(bind: payloadJSON)::jsonb, \(bind: createdAt))
            """).run()
    }

    private func remove(
        key: V2SnapshotProjectionKey,
        at sequence: UInt64,
        userID: UUID,
        sql: any SQLDatabase
    ) async throws {
        guard let sequence = Int64(exactly: sequence) else {
            throw V2UserProjectionWorkerError.invalidPayload
        }
        try await sql.raw("""
            UPDATE \(unsafeRaw: table("user_projection_versions"))
            SET valid_to_sequence = \(bind: sequence)
            WHERE user_id = \(bind: userID) AND projection_kind = \(bind: key.projectionKind)
              AND entity_key = \(bind: key.entityKey) AND valid_to_sequence IS NULL
            """).run()
    }

    private func removeRoomScope(
        roomID: UUID,
        at sequence: UInt64,
        userID: UUID,
        sql: any SQLDatabase
    ) async throws {
        guard let sequence = Int64(exactly: sequence) else {
            throw V2UserProjectionWorkerError.invalidPayload
        }
        try await sql.raw("""
            UPDATE \(unsafeRaw: table("user_projection_versions"))
            SET valid_to_sequence = \(bind: sequence)
            WHERE user_id = \(bind: userID) AND scope_room_id = \(bind: roomID)
              AND valid_to_sequence IS NULL
            """).run()
    }

    private func removeMessageReactions(
        messageID: String,
        at sequence: UInt64,
        userID: UUID,
        sql: any SQLDatabase
    ) async throws {
        guard let sequence = Int64(exactly: sequence) else {
            throw V2UserProjectionWorkerError.invalidPayload
        }
        let prefix = messageID + ":"
        try await sql.raw("""
            UPDATE \(unsafeRaw: table("user_projection_versions"))
            SET valid_to_sequence = \(bind: sequence)
            WHERE user_id = \(bind: userID)
              AND projection_kind = 'message_reaction'
              AND entity_key LIKE \(bind: prefix + "%")
              AND valid_to_sequence IS NULL
            """).run()
    }

    private struct MessageVersionIdentity: Decodable {
        let messageID: UUID
        let roomID: UUID
        let messageRevision: Int64
        enum CodingKeys: String, CodingKey {
            case messageID = "message_id", roomID = "room_id", messageRevision = "message_revision"
        }
    }

    private func messageVersionIdentity(_ payload: Data) throws -> MessageVersionIdentity {
        do {
            let value = try JSONDecoder().decode(MessageVersionIdentity.self, from: payload)
            guard value.messageRevision > 0 else { throw V2UserProjectionWorkerError.invalidPayload }
            return value
        } catch { throw V2UserProjectionWorkerError.invalidPayload }
    }

    private func jsonDataArray(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value)
    }

    private func hasRemovedContent(_ object: [String: Any]) -> Bool {
        object["is_withdrawn"] as? Bool == true && object["text"] as? String == "[removed]"
            && ["media_ids", "media_presentations", "mention_user_ids", "entities"].allSatisfy { (object[$0] as? [Any])?.isEmpty == true }
            && object["mentions_everyone"] as? Bool == false
            && ["reply_to_message_id", "forwarded_from_message_id", "forwarded_from_user_id"].allSatisfy { object[$0] == nil || object[$0] is NSNull }
    }

    private func editReplacement(_ object: [String: Any]) throws -> V2MessageEditReplacement? {
        do { return try V2MessageEditReplacement.decodeIfPresent(in: object) }
        catch { throw V2UserProjectionWorkerError.invalidPayload }
    }

    private func shouldInstallReplacement(_ replacement: V2MessageEditReplacement, key: V2SnapshotProjectionKey, userID: UUID, sql: any SQLDatabase) async throws -> Bool {
        try await shouldInstallMessageState(replacement.state, origin: replacement.acceptedEventID, key: key, userID: userID, sql: sql)
    }

    private func shouldInstallMessageState(_ incoming: V2MessageProjectionState, origin: UUID, key: V2SnapshotProjectionKey, userID: UUID, sql: any SQLDatabase) async throws -> Bool {
        guard let current = try await currentObjectIfPresent(key: key, userID: userID, sql: sql) else { return true }
        do {
            let previous = try V2MessageProjectionState(payloadJSON: String(decoding: jsonData(current.object), as: UTF8.self))
            guard current.sourceEventID == origin,
                  previous.messageID == incoming.messageID, previous.roomID == incoming.roomID,
                  previous.acceptedRoomSequence == incoming.acceptedRoomSequence,
                  previous.timelineSequence == incoming.timelineSequence,
                  previous.senderUserID == incoming.senderUserID,
                  previous.acceptedAtUnixMilliseconds == incoming.acceptedAtUnixMilliseconds
            else { throw V2UserProjectionWorkerError.invalidPayload }
            if previous.messageRevision > incoming.messageRevision {
                guard !incoming.isWithdrawn || previous.isWithdrawn else { throw V2UserProjectionWorkerError.invalidPayload }
                return false
            }
            if previous.messageRevision == incoming.messageRevision {
                guard previous == incoming else { throw V2UserProjectionWorkerError.invalidPayload }
                return false
            }
            guard !previous.isWithdrawn else { throw V2UserProjectionWorkerError.invalidPayload }
            return true
        } catch { throw V2UserProjectionWorkerError.invalidPayload }
    }

    private func currentObject(key: V2SnapshotProjectionKey, userID: UUID, sql: any SQLDatabase) async throws -> (object: [String: Any], sourceEventID: UUID) {
        guard let current = try await currentObjectIfPresent(key: key, userID: userID, sql: sql) else { throw V2UserProjectionWorkerError.invalidPayload }
        return current
    }

    private func currentObjectIfPresent(key: V2SnapshotProjectionKey, userID: UUID, sql: any SQLDatabase) async throws -> (object: [String: Any], sourceEventID: UUID)? {
        guard let row = try await sql.raw("""
            SELECT COALESCE(state.payload, version.payload)::text AS payload_json,
                   version.source_event_id
            FROM \(unsafeRaw: table("user_projection_versions")) AS version
            LEFT JOIN \(unsafeRaw: table("message_projection_state_values")) AS state
              ON state.state_id = version.message_state_id
            WHERE version.user_id = \(bind: userID)
              AND version.projection_kind = \(bind: key.projectionKind)
              AND version.entity_key = \(bind: key.entityKey)
              AND version.valid_to_sequence IS NULL
            """).first(decoding: ProjectionPayloadRow.self) else { return nil }
        guard let data = row.payloadJSON.data(using: .utf8) else { throw V2UserProjectionWorkerError.invalidPayload }
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw V2UserProjectionWorkerError.invalidPayload
            }
            object = decoded
        } catch {
            throw V2UserProjectionWorkerError.invalidPayload
        }
        return (object, row.sourceEventID)
    }

    private func groupCapabilityKey(eventType: String?, object: [String: Any]) throws -> V2SnapshotProjectionKey {
        let room = try string("room_id", object)
        switch eventType {
        case "message.pinned_changed": return try projectionKey("group_capability", "pin:\(room):\(try string("message_id", object))")
        case "group.announcement_changed": return try projectionKey("group_capability", "announcement:\(room)")
        case "group.role_permissions_changed": return try projectionKey("group_capability", "permissions:\(room):\(try string("role", object))")
        case "group.member_role_changed": return try projectionKey("group_capability", "member-role:\(room):\(try string("target_user_id", object))")
        default: throw V2UserProjectionWorkerError.invalidPayload
        }
    }

    private func projectionKey(_ kind: String, _ key: @autoclosure () throws -> String) throws -> V2SnapshotProjectionKey {
        try .init(projectionKind: kind, entityKey: key())
    }
    private func string(_ key: String, _ object: [String: Any]) throws -> String {
        guard let value = object[key] as? String, !value.isEmpty else { throw V2UserProjectionWorkerError.invalidPayload }
        return value
    }
    private func stringAllowingEmpty(_ key: String, _ object: [String: Any]) throws -> String {
        guard let value = object[key] as? String else { throw V2UserProjectionWorkerError.invalidPayload }
        return value
    }
    private func boolean(_ key: String, _ object: [String: Any]) throws -> Bool {
        guard let value = object[key] as? Bool else { throw V2UserProjectionWorkerError.invalidPayload }
        return value
    }
    private func uuid(_ key: String, _ object: [String: Any]) throws -> UUID {
        guard let value = UUID(uuidString: try string(key, object)) else {
            throw V2UserProjectionWorkerError.invalidPayload
        }
        return value
    }
    private func scopeRoomID(_ payload: Data) throws -> UUID? {
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                throw V2UserProjectionWorkerError.invalidPayload
            }
            object = decoded
        } catch {
            throw V2UserProjectionWorkerError.invalidPayload
        }
        guard let value = object["room_id"] else { return nil }
        guard let raw = value as? String, let roomID = UUID(uuidString: raw) else {
            throw V2UserProjectionWorkerError.invalidPayload
        }
        return roomID
    }
    private func jsonData(_ object: [String: Any]) throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw V2UserProjectionWorkerError.invalidPayload
        }
    }
    private func table(_ name: String) -> String { "\(schema).\(name)" }
}

public enum V2UserProjectionWorkerError: Error, Equatable, Sendable { case corruptPersistence, invalidPayload }
private struct ProjectionApplyFailure: Error, Sendable {
    let userID: UUID
    let expectedCheckpoint: Int64
    let failedSequence: Int64
    let sourceEventID: UUID
    let code: String
}
private struct ProjectionFailureCountRow: Decodable {
    let failureCount: Int64
    enum CodingKeys: String, CodingKey { case failureCount = "failure_count" }
}
private struct V2ClientLikeRecord { let sequence: UInt64; let sourceEventID: EventID; let projectionKind: String; let payload: Data }
private struct ProjectionCheckpointRow: Decodable {
    let userID: UUID; let projectedSequence: Int64
    enum CodingKeys: String, CodingKey { case userID = "user_id", projectedSequence = "projected_sequence" }
}
private struct ProjectionSyncRow: Decodable {
    let sequence: Int64
    let sourceEventID: UUID
    let projectionKind: String
    let payloadJSON: String?
    let messageStateID: UUID?
    let stateMessageID: UUID?
    let stateRoomID: UUID?
    let stateMessageRevision: Int64?
    let stateVariantKey: Int64?
    let statePayloadSchemaVersion: Int64?
    let stateOriginEventID: UUID?
    let stateEventID: UUID?
    let stateIsWithdrawn: Bool?
    let stateEventType: String?
    let stateMessageEntityKey: String?
    let createdAt: V2PostgresTimestamp

    enum CodingKeys: String, CodingKey {
        case sequence = "user_sync_sequence"
        case sourceEventID = "source_event_id"
        case projectionKind = "projection_kind"
        case payloadJSON = "payload_json"
        case messageStateID = "message_state_id"
        case stateMessageID = "state_message_id"
        case stateRoomID = "state_room_id"
        case stateMessageRevision = "state_message_revision"
        case stateVariantKey = "state_variant_key"
        case statePayloadSchemaVersion = "state_payload_schema_version"
        case stateOriginEventID = "state_origin_event_id"
        case stateEventID = "state_event_id"
        case stateIsWithdrawn = "state_is_withdrawn"
        case stateEventType = "state_event_type"
        case stateMessageEntityKey = "state_message_entity_key"
        case createdAt = "created_at"
    }
}
private struct AcceptedMessageProjectionBatchInput: Encodable, Sendable {
    let sequence: Int64
    let sourceEventID: UUID
    let messageStateID: UUID
    let messageID: UUID
    let entityKey: String
    let roomID: UUID
    let createdAtPostgresMicroseconds: Int64

    enum CodingKeys: String, CodingKey {
        case sequence
        case sourceEventID = "source_event_id"
        case messageStateID = "message_state_id"
        case messageID = "message_id"
        case entityKey = "entity_key"
        case roomID = "room_id"
        case createdAtPostgresMicroseconds = "created_at_postgres_microseconds"
    }
}
private struct ProjectionBatchCountRow: Decodable {
    let insertedCount: Int
    enum CodingKeys: String, CodingKey { case insertedCount = "inserted_count" }
}
private struct ProjectionPayloadRow: Decodable {
    let payloadJSON: String; let sourceEventID: UUID
    enum CodingKeys: String, CodingKey { case payloadJSON = "payload_json", sourceEventID = "source_event_id" }
}

private struct ReactionSnapshotOrder: Decodable, Equatable {
    let roomID: UUID
    let messageID: UUID
    let actorID: UUID
    let reaction: String
    let action: String
    let roomSequence: Int64
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id", messageID = "message_id", actorID = "actor_user_id"
        case reaction, action, roomSequence = "room_sequence"
    }
}

private struct ReactionMessageWithdrawal: Decodable { let withdrawn: Bool }

private struct GroupPolicyProjectionPayloadRow: Decodable {
    let entityKey: String; let payloadJSON: String; let sourceEventID: UUID
    enum CodingKeys: String, CodingKey {
        case entityKey = "entity_key", payloadJSON = "payload_json", sourceEventID = "source_event_id"
    }
}
