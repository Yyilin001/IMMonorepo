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

/// Folds a bounded, contiguous sync-log batch into canonical current snapshot
/// items. The checkpoint row is locked for the whole short transaction, so
/// multiple gateway processes can safely run this worker concurrently.
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
            var expected = checkpoint.projectedSequence + 1
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
                    guard firstInput.sequence == expected,
                          batch.enumerated().allSatisfy({ offset, input in
                              input.sequence == expected + Int64(offset)
                          })
                    else { throw V2UserProjectionWorkerError.corruptPersistence }
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
                    expected += Int64(batch.count)
                    rowIndex = nextIndex
                    continue
                }
                let row = rows[rowIndex]
                try Task.checkCancellation()
                guard row.sequence == expected else {
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
                expected += 1
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
                    SET projected_sequence = \(bind: expected - 1), state = 'ready',
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

    /// Returns a typed fast-path input only for the immutable revision-one
    /// state shape produced by `PostgresV2MessageProjectionStateRepository`.
    /// Full payload validation belongs to that single state-creation boundary;
    /// this recipient-specific path rechecks identity, revision, room, event
    /// and deterministic state ID without decoding the same body per user.
    /// Anything else deliberately falls back to the established state machine.
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
        let microseconds = (row.createdAt.timeIntervalSince1970 * 1_000_000).rounded(.down)
        guard microseconds.isFinite,
              microseconds >= Double(Int64.min), microseconds <= Double(Int64.max)
        else { return nil }
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
            createdAtMicroseconds: Int64(microseconds)
        )
    }

    /// Closes and inserts a run of independent accepted-message versions in
    /// one PostgreSQL round trip. The final count is an integrity fence: one
    /// invalid state throws and rolls the entire surrounding checkpoint
    /// transaction back, exactly like the sequential implementation.
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
                       value.created_at_microseconds
                FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb) AS value(
                    sequence bigint, source_event_id uuid, message_state_id uuid,
                    message_id uuid, entity_key text, room_id uuid,
                    created_at_microseconds bigint
                )
            ), validated AS MATERIALIZED (
                SELECT input.sequence, input.source_event_id, input.message_state_id,
                       input.message_id, input.entity_key, input.created_at_microseconds,
                       state.room_id, state.origin_event_id, state.payload
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
            ), closed AS (
                UPDATE \(unsafeRaw: table("user_projection_versions")) AS version
                SET valid_to_sequence = validated.sequence
                FROM validated
                WHERE version.user_id = \(bind: userID)
                  AND version.projection_kind = 'message'
                  AND version.entity_key = validated.entity_key
                  AND version.valid_to_sequence IS NULL
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
                       to_timestamp(validated.created_at_microseconds / 1000000)
                         + (validated.created_at_microseconds % 1000000)
                           * INTERVAL '1 microsecond'
                FROM validated
                ORDER BY validated.sequence
                RETURNING 1
            )
            SELECT COUNT(*) AS inserted_count FROM inserted
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
        createdAt: Date,
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
            switch try string("action", object) {
            case "add":
                try await replace(key: key, record: record, payload: record.payload, userID: userID, createdAt: createdAt, sql: sql)
            case "remove":
                try await remove(key: key, at: record.sequence, userID: userID, sql: sql)
            default:
                throw V2UserProjectionWorkerError.invalidPayload
            }
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

    private func applyMembership(
        record: V2ClientLikeRecord,
        object: [String: Any],
        userID: UUID,
        createdAt: Date,
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
        case "group_capability" where eventType == "message.pinned_changed":
            return try boolean("is_pinned", object) == false
        case "group_capability" where eventType == "group.announcement_changed":
            return try stringAllowingEmpty("body", object).isEmpty
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
        createdAt: Date,
        key: V2SnapshotProjectionKey,
        sql: any SQLDatabase
    ) async throws {
        if let messageStateID {
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
            try await replace(key: key, record: record, payload: record.payload, userID: userID, createdAt: createdAt, sql: sql)
        case "message.edited":
            let stored = try await currentObject(key: key, userID: userID, sql: sql)
            var current = stored.object
            current["text"] = object["text"]
            current["entities"] = object["entities"] ?? []
            current["message_revision"] = object["message_revision"]
            try await replace(key: key, record: record, payload: try jsonData(current), sourceEventID: stored.sourceEventID, userID: userID, createdAt: createdAt, sql: sql)
        case "message.withdrawn", "message.redacted":
            let stored = try await currentObject(key: key, userID: userID, sql: sql)
            var current = stored.object
            current["message_revision"] = object["message_revision"]
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
        createdAt: Date,
        key: V2SnapshotProjectionKey,
        sql: any SQLDatabase
    ) async throws {
        guard let stored = try await PostgresV2MessageProjectionStateRepository(schema: schema)
            .load(stateID: messageStateID, sql: sql),
              stored.stateID == messageStateID,
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
        case "message.edited", "message.withdrawn", "message.redacted":
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
        createdAt: Date,
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

    private func replace(key: V2SnapshotProjectionKey, record: V2ClientLikeRecord, payload: Data, sourceEventID: UUID? = nil, userID: UUID, createdAt: Date, sql: any SQLDatabase) async throws {
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

    private func currentObject(key: V2SnapshotProjectionKey, userID: UUID, sql: any SQLDatabase) async throws -> (object: [String: Any], sourceEventID: UUID) {
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
            """).first(decoding: ProjectionPayloadRow.self),
              let data = row.payloadJSON.data(using: .utf8)
        else { throw V2UserProjectionWorkerError.invalidPayload }
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
    let createdAt: Date

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
    let createdAtMicroseconds: Int64

    enum CodingKeys: String, CodingKey {
        case sequence
        case sourceEventID = "source_event_id"
        case messageStateID = "message_state_id"
        case messageID = "message_id"
        case entityKey = "entity_key"
        case roomID = "room_id"
        case createdAtMicroseconds = "created_at_microseconds"
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
