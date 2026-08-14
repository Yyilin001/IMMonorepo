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

    public init(
        database: any Database,
        schema: String = "im_v2",
        batchSize: Int = 100,
        retryPolicy: V2DurableRetryPolicy = .standard
    ) {
        precondition(batchSize > 0)
        precondition(schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil)
        self.database = database
        self.schema = schema
        self.batchSize = batchSize
        self.retryPolicy = retryPolicy
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
                FROM \(unsafeRaw: table("user_projection_checkpoints")) AS checkpoint
                JOIN \(unsafeRaw: table("user_sync_sequences")) AS sequence
                  ON sequence.user_id = checkpoint.user_id
                WHERE checkpoint.projected_sequence < sequence.next_sequence
                  AND checkpoint.state = 'ready'
                  AND (checkpoint.next_attempt_at IS NULL OR checkpoint.next_attempt_at <= \(bind: now))
                  AND (checkpoint.migration_fence_expires_at IS NULL
                       OR checkpoint.migration_fence_expires_at <= now())
                ORDER BY checkpoint.updated_at, checkpoint.user_id
                FOR UPDATE OF checkpoint SKIP LOCKED
                LIMIT 1
                """).first(decoding: ProjectionCheckpointRow.self) else {
                return .init(claimed: false, appliedRecordCount: 0)
            }
            let rows = try await sql.raw("""
                SELECT log.user_sync_sequence, log.source_event_id, log.projection_kind,
                       CASE WHEN log.payload_storage = 'inline' THEN log.payload ELSE shared.payload END::text AS payload_json,
                       log.created_at
                FROM \(unsafeRaw: table("user_sync_log")) AS log
                LEFT JOIN \(unsafeRaw: table("fanout_sync_payloads")) AS shared
                  ON shared.source_event_id = log.source_event_id
                 AND shared.projection_kind = log.projection_kind
                WHERE log.user_id = \(bind: checkpoint.userID)
                  AND log.user_sync_sequence > \(bind: checkpoint.projectedSequence)
                ORDER BY log.user_sync_sequence
                LIMIT \(bind: batchSize)
                """).all(decoding: ProjectionSyncRow.self)
            guard !rows.isEmpty else { throw V2UserProjectionWorkerError.corruptPersistence }
            var expected = checkpoint.projectedSequence + 1
            for row in rows {
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
            }
            try await sql.raw("""
                UPDATE \(unsafeRaw: table("user_projection_checkpoints"))
                SET projected_sequence = \(bind: expected - 1), state = 'ready',
                    failure_count = 0, failed_sequence = NULL,
                    next_attempt_at = NULL, last_failure_code = NULL,
                    paused_at = NULL, updated_at = \(bind: now)
                WHERE user_id = \(bind: checkpoint.userID)
                """).run()
            return .init(claimed: true, appliedRecordCount: rows.count)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as ProjectionApplyFailure {
            return try await recordFailure(failure, now: now)
        }
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
                return .init(
                    claimed: true,
                    appliedRecordCount: 0,
                    failedRecordCount: 1,
                    pausedUserCount: 1
                )
            }
        }
    }

    private func apply(record: V2ClientLikeRecord, userID: UUID, createdAt: Date, sql: any SQLDatabase) async throws {
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
            try await applyMessage(record: record, object: object, eventType: eventType, userID: userID, createdAt: createdAt, key: key, sql: sql)
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

    private func applyMessage(record: V2ClientLikeRecord, object: [String: Any], eventType: String?, userID: UUID, createdAt: Date, key: V2SnapshotProjectionKey, sql: any SQLDatabase) async throws {
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
            SELECT payload::text AS payload_json, source_event_id
            FROM \(unsafeRaw: table("user_projection_versions"))
            WHERE user_id = \(bind: userID) AND projection_kind = \(bind: key.projectionKind)
              AND entity_key = \(bind: key.entityKey) AND valid_to_sequence IS NULL
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
    let sequence: Int64; let sourceEventID: UUID; let projectionKind: String; let payloadJSON: String?; let createdAt: Date
    enum CodingKeys: String, CodingKey { case sequence = "user_sync_sequence", sourceEventID = "source_event_id", projectionKind = "projection_kind", payloadJSON = "payload_json", createdAt = "created_at" }
}
private struct ProjectionPayloadRow: Decodable {
    let payloadJSON: String; let sourceEventID: UUID
    enum CodingKeys: String, CodingKey { case payloadJSON = "payload_json", sourceEventID = "source_event_id" }
}
