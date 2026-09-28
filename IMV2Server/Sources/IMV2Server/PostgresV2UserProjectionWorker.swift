import FluentKit
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
                ORDER BY ready.available_at, ready.enqueued_at, ready.user_id
                FOR UPDATE OF ready, checkpoint SKIP LOCKED
                LIMIT 1
                """).first(decoding: ProjectionCheckpointRow.self) else {
                return .init(claimed: false, appliedRecordCount: 0)
            }
            let rows = try await sql.raw("""
                SELECT log.user_sync_sequence, log.source_event_id, log.projection_kind,
                       log.payload::text AS payload_json, log.created_at
                FROM \(unsafeRaw: table("user_sync_log")) AS log
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
                let row = rows[rowIndex]
                try Task.checkCancellation()
                guard lastApplied < Int64.max, row.sequence == lastApplied + 1 else {
                    throw V2UserProjectionWorkerError.corruptPersistence
                }
                if ["message", "message_reaction", "group_capability", "moderation"].contains(row.projectionKind) {
                    throw ProjectionApplyFailure(userID: checkpoint.userID,
                        expectedCheckpoint: checkpoint.projectedSequence, failedSequence: row.sequence,
                        sourceEventID: row.sourceEventID, code: "public_content_in_personal_stream")
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
                // 我方事务回滚后，另一工作器已推进或暂停该用户。
                // 失败的认领仍代表有用工作，但不能覆盖较新的检查点状态。
                return .init(claimed: true, appliedRecordCount: 0)
            }
            guard checkpoint.failureCount < Int64.max else {
                throw V2UserProjectionWorkerError.corruptPersistence
            }
            let attempt = Int(clamping: checkpoint.failureCount + 1)
            let disposition: V2DurableRetryDisposition = failure.code == "public_content_in_personal_stream"
                ? .pause : retryPolicy.disposition(attempt: attempt, claimToken: failure.sourceEventID, now: now)
            switch disposition {
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
        if record.projectionKind != "room", record.projectionKind != "membership",
           let room = (object["room_id"] as? String).flatMap(UUID.init(uuidString:)),
           try await sql.raw("""
               SELECT TRUE AS revoked FROM \(unsafeRaw: table("user_projection_versions"))
               WHERE user_id = \(bind: userID) AND projection_kind = 'room' AND scope_room_id = \(bind: room)
                 AND valid_to_sequence IS NULL AND payload->>'viewer_is_member' = 'false'
               """).first(decoding: ProjectionRoomRevocationRow.self) != nil { return }
        let eventType = object["event_type"] as? String
        let key: V2SnapshotProjectionKey
        switch record.projectionKind {
        case "room", "membership":
            try await applyMembership(record: record, object: object, userID: userID, createdAt: createdAt, sql: sql)
            return
        case "relationship": key = try projectionKey("relationship", string("target_user_id", object))
        case "user_block": key = try projectionKey("user_block", string("target_user_id", object))
        case "stranger_message_permission", "user_add_permission", "live_activity_preferences":
            key = try projectionKey(record.projectionKind, "singleton")
            let incoming = try personalPreferenceRevision(record.payload)
            if let prior = try await currentObjectIfPresent(key: key, userID: userID, sql: sql) {
                let current = try personalPreferenceRevision(jsonData(prior.object))
                if incoming < current { return }
                if incoming == current {
                    guard NSDictionary(dictionary: object).isEqual(to: prior.object) else {
                        throw V2UserProjectionWorkerError.invalidPayload
                    }
                    return
                }
            }
        case "read_receipt_preferences":
            key = try projectionKey(record.projectionKind, "singleton")
            let incoming = try receiptPreferences(record.payload)
            if let prior = try await currentObjectIfPresent(key: key, userID: userID, sql: sql) {
                let current = try receiptPreferences(jsonData(prior.object))
                if incoming.revision < current.revision { return }
                if incoming.revision == current.revision {
                    guard incoming == current else { throw V2UserProjectionWorkerError.invalidPayload }
                    return
                }
            }
        case "own_read_watermark":
            let incoming = try ownReadWatermark(record.payload)
            key = try projectionKey(record.projectionKind, incoming.roomID.uuidString.lowercased())
            if let prior = try await currentObjectIfPresent(key: key, userID: userID, sql: sql) {
                let current = try ownReadWatermark(jsonData(prior.object))
                guard incoming.readThroughRoomSequence > current.readThroughRoomSequence ||
                    (incoming.readThroughRoomSequence == current.readThroughRoomSequence &&
                     incoming.recordedAtMilliseconds > current.recordedAtMilliseconds) else { return }
            }
        case "direct_sending_capability":
            key = try projectionKey(record.projectionKind, string("room_id", object))
            let incoming = try sendingCapability(record.payload)
            if let prior = try await currentObjectIfPresent(key: key, userID: userID, sql: sql) {
                let current = try sendingCapability(jsonData(prior.object))
                if incoming.stateVersion < current.stateVersion { return }
                if incoming.stateVersion == current.stateVersion {
                    guard incoming == current else { throw V2UserProjectionWorkerError.invalidPayload }
                    return
                }
            }
        case "direct_room_profile":
            key = try projectionKey(record.projectionKind, string("room_id", object))
            let incoming = try directProfile(record.payload)
            if let prior = try await currentObjectIfPresent(key: key, userID: userID, sql: sql) {
                let current = try directProfile(jsonData(prior.object))
                guard incoming.targetUserID == current.targetUserID,
                      incoming.roomCreatedAtMilliseconds == current.roomCreatedAtMilliseconds else { throw V2UserProjectionWorkerError.invalidPayload }
                if incoming.revision < current.revision { return }
                if incoming.revision == current.revision {
                    guard incoming == current else { throw V2UserProjectionWorkerError.invalidPayload }
                    return
                }
            }
        case "direct_read_receipt":
            let incoming = try directReceipt(record.payload)
            key = try projectionKey(record.projectionKind, incoming.roomID.uuidString.lowercased())
            if let prior = try await currentObjectIfPresent(key: key, userID: userID, sql: sql) {
                let current = try directReceipt(jsonData(prior.object))
                guard incoming.readerUserID == current.readerUserID else {
                    throw V2UserProjectionWorkerError.invalidPayload
                }
                let older = incoming.readerPreferenceRevision < current.readerPreferenceRevision ||
                    incoming.viewerPreferenceRevision < current.viewerPreferenceRevision
                let newer = incoming.readerPreferenceRevision > current.readerPreferenceRevision ||
                    incoming.viewerPreferenceRevision > current.viewerPreferenceRevision
                guard !(older && newer) else { throw V2UserProjectionWorkerError.invalidPayload }
                if older { return }
                if !newer {
                    guard incoming.isVisible == current.isVisible else {
                        throw V2UserProjectionWorkerError.invalidPayload
                    }
                    if !incoming.isVisible { return }
                    if incoming.readThroughRoomSequence < current.readThroughRoomSequence { return }
                    if incoming.readThroughRoomSequence == current.readThroughRoomSequence,
                       incoming.recordedAtMilliseconds <= current.recordedAtMilliseconds { return }
                }
            }
        case "conversation_state", "message_favorite", "contact_alias":
            let entity = record.projectionKind == "contact_alias" ? "target_user_id" : (record.projectionKind == "conversation_state" ? "room_id" : "message_id")
            key = try projectionKey(record.projectionKind, string(entity, object))
            let incoming = try personalPreferenceRevision(record.payload)
            if let prior = try await currentObjectIfPresent(key:key,userID:userID,sql:sql) {
                let current = try personalPreferenceRevision(jsonData(prior.object))
                if incoming < current { return }
                if incoming == current {
                    guard try jsonData(object) == jsonData(prior.object) else { throw V2UserProjectionWorkerError.invalidPayload }
                    return
                }
            }
        case "timeline_activity": key = try projectionKey(record.projectionKind, record.sourceEventID.rawValue)
        case "profile_invalidation": key = try projectionKey(record.projectionKind, string("user_id", object))
        default: throw V2UserProjectionWorkerError.invalidPayload
        }
        if try representsAbsence(record: record, object: object, eventType: eventType) {
            try await remove(key: key, at: record.sequence, userID: userID, sql: sql)
            return
        }
        try await replace(key: key, record: record, payload: record.payload, userID: userID, createdAt: createdAt, sql: sql)
    }

    private struct PersonalPreferenceRevisionPayload:Decodable { let revision:UInt64 }
    private func personalPreferenceRevision(_ data:Data) throws -> UInt64 {
        guard let value=try? JSONDecoder().decode(PersonalPreferenceRevisionPayload.self,from:data),
              value.revision>0,value.revision<=UInt64(Int64.max) else { throw V2UserProjectionWorkerError.invalidPayload }
        return value.revision
    }

    private struct ReceiptPreferencesPayload: Decodable, Equatable {
        let revision: UInt64
        let allowsDirect: Bool
        let allowsGroup: Bool
        let updatedAt: Int64
        enum CodingKeys: String, CodingKey {
            case revision = "preference_revision", updatedAt = "updated_at_ms"
            case allowsDirect = "allows_direct_read_receipts", allowsGroup = "allows_group_read_receipts"
        }
    }

    private func receiptPreferences(_ data: Data) throws -> ReceiptPreferencesPayload {
        guard let value = try? JSONDecoder().decode(ReceiptPreferencesPayload.self, from: data),
              value.revision > 0, value.revision <= UInt64(Int64.max), value.updatedAt >= 0 else {
            throw V2UserProjectionWorkerError.invalidPayload
        }
        return value
    }

    private struct DirectReceiptPayload: Decodable {
        let roomID: UUID
        let readerUserID: UUID
        let readThroughRoomSequence: UInt64
        let recordedAtMilliseconds: Int64
        let isVisible: Bool
        let readerPreferenceRevision: UInt64
        let viewerPreferenceRevision: UInt64
        enum CodingKeys: String, CodingKey {
            case roomID = "room_id", readerUserID = "reader_user_id"
            case readThroughRoomSequence = "read_through_room_sequence"
            case recordedAtMilliseconds = "recorded_at_ms", isVisible = "is_visible"
            case readerPreferenceRevision = "reader_preference_revision"
            case viewerPreferenceRevision = "viewer_preference_revision"
        }
    }

    private func directReceipt(_ data: Data) throws -> DirectReceiptPayload {
        guard let value = try? JSONDecoder().decode(DirectReceiptPayload.self, from: data),
              value.readThroughRoomSequence <= UInt64(Int64.max),
              value.readerPreferenceRevision <= UInt64(Int64.max),
              value.viewerPreferenceRevision <= UInt64(Int64.max),
              value.isVisible || value.readThroughRoomSequence == 0
        else { throw V2UserProjectionWorkerError.invalidPayload }
        return value
    }

    private struct DirectProfilePayload: Decodable, Equatable {
        let targetUserID: UserID
        let publicHandle: String
        let displayName: String
        let accountKind: String
        let revision: UInt64
        let updatedAtMilliseconds: Int64
        let roomCreatedAtMilliseconds: Int64
        enum CodingKeys: String, CodingKey {
            case targetUserID = "target_user_id"
            case publicHandle = "public_handle"
            case displayName = "display_name"
            case accountKind = "account_kind"
            case revision
            case updatedAtMilliseconds = "updated_at_ms"
            case roomCreatedAtMilliseconds = "room_created_at_ms"
        }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            targetUserID = try UserID(values.decode(String.self, forKey: .targetUserID))
            publicHandle = try values.decode(String.self, forKey: .publicHandle)
            displayName = try values.decode(String.self, forKey: .displayName)
            accountKind = try values.decode(String.self, forKey: .accountKind)
            revision = try values.decode(UInt64.self, forKey: .revision)
            updatedAtMilliseconds = try values.decode(Int64.self, forKey: .updatedAtMilliseconds)
            roomCreatedAtMilliseconds = try values.decode(Int64.self, forKey: .roomCreatedAtMilliseconds)
        }
    }

    private func directProfile(_ data: Data) throws -> DirectProfilePayload {
        guard let value = try? JSONDecoder().decode(DirectProfilePayload.self, from: data),
              value.revision > 0, value.revision <= UInt64(Int64.max),
              value.updatedAtMilliseconds >= 0, value.roomCreatedAtMilliseconds >= 0
        else { throw V2UserProjectionWorkerError.invalidPayload }
        return value
    }

    private struct SendingCapabilityPayload: Decodable, Equatable {
        let stateVersion: UInt64
        let canSend: Bool
        let updatedAtMilliseconds: Int64
        enum CodingKeys: String, CodingKey {
            case stateVersion = "state_version"
            case canSend = "can_send"
            case updatedAtMilliseconds = "updated_at_ms"
        }
    }

    private func sendingCapability(_ data: Data) throws -> SendingCapabilityPayload {
        guard let value = try? JSONDecoder().decode(SendingCapabilityPayload.self, from: data),
              value.stateVersion > 0, value.stateVersion <= UInt64(Int64.max),
              value.updatedAtMilliseconds >= 0
        else { throw V2UserProjectionWorkerError.invalidPayload }
        return value
    }

    private func ownReadWatermark(_ data: Data) throws -> OwnReadWatermarkPayload {
        guard let value = try? JSONDecoder().decode(OwnReadWatermarkPayload.self, from: data),
              value.readThroughRoomSequence > 0,
              value.readThroughRoomSequence <= UInt64(Int64.max) else { throw V2UserProjectionWorkerError.invalidPayload }
        return value
    }

    private func applyMembership(
        record: V2ClientLikeRecord,
        object: [String: Any],
        userID: UUID,
        createdAt: V2PostgresTimestamp,
        sql: any SQLDatabase
    ) async throws {
        let isCreation = record.projectionKind == "room"
        guard object["event_type"] as? String == (isCreation ? "room.created" : "membership_changed") else {
            throw V2UserProjectionWorkerError.invalidPayload
        }
        let roomValue = try string("room_id", object)
        guard let roomID = UUID(uuidString: roomValue) else { throw V2UserProjectionWorkerError.invalidPayload }
        let targetUserID = isCreation ? userID : UUID(uuidString: try string("target_user_id", object))
        let action = isCreation ? "add" : try string("action", object)
        guard targetUserID != nil, action == "add" || action == "remove" else { throw V2UserProjectionWorkerError.invalidPayload }
        struct Revision: Decodable {
            let value: Int64
            enum CodingKeys: String, CodingKey { case value = "membership_revision" }
        }
        let revision: Int64
        do { revision = try JSONDecoder().decode(Revision.self, from: record.payload).value }
        catch { throw V2UserProjectionWorkerError.invalidPayload }
        guard revision > 0 else { throw V2UserProjectionWorkerError.invalidPayload }
        let key = try projectionKey("room", roomValue)
        let prior = try await currentObjectIfPresent(key: key, userID: userID, sql: sql)
        let priorWasOwn = prior.map {
            $0.object["event_type"] as? String == "room.created" ||
                ($0.object["target_user_id"] as? String).flatMap(UUID.init(uuidString:)) == userID
        } ?? false
        var ownRevision = (prior?.object["viewer_membership_revision"] as? NSNumber)?.int64Value ??
            (priorWasOwn ? (prior?.object["membership_revision"] as? NSNumber)?.int64Value ?? 0 : 0)
        var ownSource = (prior?.object["viewer_membership_source_event_id"] as? String) ?? prior?.sourceEventID.uuidString
        var isMember = (prior?.object["viewer_is_member"] as? Bool) ??
            !(priorWasOwn && prior?.object["action"] as? String == "remove")
        if targetUserID == userID {
            if revision < ownRevision { return }
            if revision == ownRevision {
                guard ownSource.flatMap(UUID.init(uuidString:)) == record.sourceEventID.uuidValue,
                      isMember == (action == "add") else { throw V2UserProjectionWorkerError.invalidPayload }
                return
            }
            ownRevision = revision
            ownSource = record.sourceEventID.rawValue
            isMember = action == "add"
        } else {
            // 其他成员的变更不能恢复此用户已撤销的成员资格。
            guard isMember else { return }
            if let previousRevision = (prior?.object["membership_revision"] as? NSNumber)?.int64Value,
               revision <= previousRevision { return }
        }
        if !isMember {
            try await removeRoomScope(roomID: roomID, at: record.sequence, userID: userID, sql: sql)
        }
        // 在快照中保留房间身份的否定记录；上方已关闭其作用域的内容。
        var state = object
        if ownRevision > 0, let ownSource {
            state["viewer_membership_revision"] = ownRevision
            state["viewer_membership_source_event_id"] = ownSource
            state["viewer_is_member"] = isMember
        }
        try await replace(key: key, record: record, payload: jsonData(state), userID: userID, createdAt: createdAt, sql: sql)
    }

    private func representsAbsence(
        record: V2ClientLikeRecord,
        object: [String: Any],
        eventType: String?
    ) throws -> Bool {
        switch record.projectionKind {
        case "relationship": return try string("state", object) == "none"
        case "user_block": return try boolean("is_blocked", object) == false
        case "message_favorite", "conversation_state": return false // Keep the revision even for cleared state.
        default: return false
        }
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

    private func currentObjectIfPresent(key: V2SnapshotProjectionKey, userID: UUID, sql: any SQLDatabase) async throws -> (object: [String: Any], sourceEventID: UUID)? {
        guard let row = try await sql.raw("""
            SELECT version.payload::text AS payload_json,
                   version.source_event_id
            FROM \(unsafeRaw: table("user_projection_versions")) AS version
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
    let createdAt: V2PostgresTimestamp

    enum CodingKeys: String, CodingKey {
        case sequence = "user_sync_sequence"
        case sourceEventID = "source_event_id"
        case projectionKind = "projection_kind"
        case payloadJSON = "payload_json"
        case createdAt = "created_at"
    }
}

private struct ProjectionPayloadRow: Decodable {
    let payloadJSON: String; let sourceEventID: UUID
    enum CodingKeys: String, CodingKey { case payloadJSON = "payload_json", sourceEventID = "source_event_id" }
}

private struct ProjectionRoomRevocationRow: Decodable { let revoked: Bool }

private struct OwnReadWatermarkPayload: Decodable {
    let roomID: UUID
    let readThroughRoomSequence: UInt64
    let recordedAtMilliseconds: Int64
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case readThroughRoomSequence = "read_through_room_sequence"
        case recordedAtMilliseconds = "recorded_at_ms"
    }
}
