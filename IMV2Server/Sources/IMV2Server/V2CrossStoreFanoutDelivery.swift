import Fluent
import Foundation
import IMV2Core
import SQLKit

/// 由控制存储为单次扇出效果准备的不可变源载荷。
///
/// 它刻意只包含逻辑 ID，绝不包含桶地址或连接串。
public struct V2FanoutProjectionInput: Sendable {
    public let sourceEventID: EventID
    public let targetUserID: UserID
    public let projectionKind: String
    public let eventPayloadJSON: String
    public let messageState: V2FanoutMessageProjectionState?

    public init(
        sourceEventID: EventID,
        targetUserID: UserID,
        projectionKind: String,
        eventPayloadJSON: String,
        messageState: V2FanoutMessageProjectionState? = nil
    ) {
        self.sourceEventID = sourceEventID
        self.targetUserID = targetUserID
        self.projectionKind = projectionKind
        self.eventPayloadJSON = eventPayloadJSON
        self.messageState = messageState
    }
}

/// 单个规范消息状态的不可变跨存储传输体。
///
/// 它不携带桶或连接信息，并使用全局稳定的状态 ID，
/// 因此目标分片重试时可以校验或复用，无需重映射标识符。
public struct V2FanoutMessageProjectionState: Equatable, Sendable {
    public let stateID: UUID
    public let messageID: UUID
    public let roomID: UUID
    public let messageRevision: Int64
    public let variantKey: Int16
    public let originEventID: UUID
    public let stateEventID: UUID?
    public let isWithdrawn: Bool
    public let payloadSchemaVersion: Int16
    public let payloadJSON: String
    public let createdAt: Date
    // Database-originated states retain their native timestamp alongside the
    // Date API, including values that Date cannot represent exactly.
    private(set) var persistedCreatedAt: V2PostgresTimestamp?

    public init(
        stateID: UUID,
        messageID: UUID,
        roomID: UUID,
        messageRevision: Int64,
        variantKey: Int16,
        originEventID: UUID,
        stateEventID: UUID?,
        isWithdrawn: Bool,
        payloadSchemaVersion: Int16,
        payloadJSON: String,
        createdAt: Date
    ) {
        self.stateID = stateID
        self.messageID = messageID
        self.roomID = roomID
        self.messageRevision = messageRevision
        self.variantKey = variantKey
        self.originEventID = originEventID
        self.stateEventID = stateEventID
        self.isWithdrawn = isWithdrawn
        self.payloadSchemaVersion = payloadSchemaVersion
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
        self.persistedCreatedAt = try? V2PostgresTimestamp(date: createdAt)
    }

    init(_ value: V2StoredMessageProjectionState, persistedCreatedAt: V2PostgresTimestamp? = nil) {
        self.init(
            stateID: value.stateID,
            messageID: value.messageID,
            roomID: value.roomID,
            messageRevision: value.messageRevision,
            variantKey: value.variantKey,
            originEventID: value.originEventID,
            stateEventID: value.stateEventID,
            isWithdrawn: value.isWithdrawn,
            payloadSchemaVersion: value.payloadSchemaVersion,
            payloadJSON: value.payloadJSON,
            createdAt: value.createdAt
        )
        if let persistedCreatedAt { self.persistedCreatedAt = persistedCreatedAt }
    }

    var stored: V2StoredMessageProjectionState {
        .init(
            stateID: stateID,
            messageID: messageID,
            roomID: roomID,
            messageRevision: messageRevision,
            variantKey: variantKey,
            originEventID: originEventID,
            stateEventID: stateEventID,
            isWithdrawn: isWithdrawn,
            payloadSchemaVersion: payloadSchemaVersion,
            payloadJSON: payloadJSON,
            createdAt: createdAt
        )
    }
}

/// 单个有界远端目标投影及其控制存储确认的隐私安全耗时。
///
/// 它刻意只包含聚合计数与耗时：房间、事件、用户、桶与载荷值
/// 绝不会到达观察者。
public struct V2CrossStoreFanoutBatchTiming: Equatable, Sendable {
    public let targetCount: Int
    public let migrationReadMilliseconds: Int
    public let targetProjectionMilliseconds: Int
    public let controlCompletionMilliseconds: Int
    public let totalMilliseconds: Int

    public init(
        targetCount: Int,
        migrationReadMilliseconds: Int,
        targetProjectionMilliseconds: Int,
        controlCompletionMilliseconds: Int,
        totalMilliseconds: Int
    ) {
        self.targetCount = targetCount
        self.migrationReadMilliseconds = migrationReadMilliseconds
        self.targetProjectionMilliseconds = targetProjectionMilliseconds
        self.controlCompletionMilliseconds = controlCompletionMilliseconds
        self.totalMilliseconds = totalMilliseconds
    }
}

/// 远端扇出的可选诊断接缝。
///
/// 生产组合可以保持未设置；记录器不得参与投递正确性。
public protocol V2CrossStoreFanoutDeliveryTimingRecording: Sendable {
    func record(_ timing: V2CrossStoreFanoutBatchTiming) async
}

/// 用户分片迁移期间镜像的、已提交的用户同步记录。
///
/// 与扇出输入不同，它保留源分配的序号与载荷：直接/社交权威
/// 先在控制存储提交，且绝不允许在目标分片上再制造第二个用户可见事件。
public struct V2UserSyncProjectionMirror: Sendable {
    public let userID: UserID
    public let sequence: UInt64
    public let sourceEventID: EventID
    public let projectionKind: String
    public let payloadJSON: String
    public let createdAt: Date

    public init(userID: UserID, sequence: UInt64, sourceEventID: EventID, projectionKind: String, payloadJSON: String, createdAt: Date) {
        self.userID = userID
        self.sequence = sequence
        self.sourceEventID = sourceEventID
        self.projectionKind = projectionKind
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
    }
}

/// 跨存储扇出投递的目标存储一侧。
///
/// 收件箱写入与序号/日志写入共享同一个目标事务。若进程在控制存储完成前退出，
/// 重试会返回已提交的序号，而不是产生第二条用户可见记录。
public struct PostgresV2UserShardFanoutProjector: Sendable {
    private let database: any Database
    private let schema: String
    private let consumerName = "v2-fanout-delivery"
    private let payloadWriteMode: V2FanoutPayloadWriteMode

    public init(
        database: any Database,
        schema: String,
        payloadWriteMode: V2FanoutPayloadWriteMode = .body
    ) throws {
        guard schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
            throw V2UserShardStorageRegistryError.invalidLocation
        }
        self.database = database
        self.schema = schema
        self.payloadWriteMode = payloadWriteMode
    }

    public func project(_ input: V2FanoutProjectionInput, now: Date) async throws -> UInt64 {
        guard v2PostgresTimestampCanEncode(now) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        guard let sourceEventID = UUID(uuidString: input.sourceEventID.rawValue),
              let targetUserID = UUID(uuidString: input.targetUserID.rawValue)
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let inserted = try await sql.raw("""
                INSERT INTO \(unsafeRaw: table("consumer_inbox"))
                    (consumer_name, source_event_id, target_user_id, projection_kind, committed_at)
                VALUES (\(bind: consumerName), \(bind: sourceEventID), \(bind: targetUserID), \(bind: input.projectionKind), \(bind: now))
                ON CONFLICT DO NOTHING
                RETURNING source_event_id
                """).first(decoding: CrossStoreInboxInsertRow.self) != nil
            if !inserted {
                guard let existing = try await sql.raw("""
                    SELECT user_sync_sequence
                    FROM \(unsafeRaw: table("consumer_inbox"))
                    WHERE consumer_name = \(bind: consumerName)
                      AND target_user_id = \(bind: targetUserID)
                      AND source_event_id = \(bind: sourceEventID)
                      AND projection_kind = \(bind: input.projectionKind)
                      AND user_sync_sequence IS NOT NULL
                    """).first(decoding: CrossStoreSequenceRow.self)
                else { throw V2RoomWriteStoreError.corruptPersistenceState }
                return try crossStoreUnsigned(existing.userSyncSequence)
            }
            guard let sequence = try await sql.raw("""
                INSERT INTO \(unsafeRaw: table("user_sync_sequences")) (user_id, next_sequence)
                VALUES (\(bind: targetUserID), 1)
                ON CONFLICT (user_id)
                DO UPDATE SET next_sequence = \(unsafeRaw: table("user_sync_sequences")).next_sequence + 1
                WHERE \(unsafeRaw: table("user_sync_sequences")).next_sequence < \(bind: Int64.max)
                RETURNING next_sequence AS user_sync_sequence
                """).first(decoding: CrossStoreSequenceRow.self)
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            if let messageState = input.messageState {
                guard input.projectionKind == "message" else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                try await PostgresV2MessageProjectionStateRepository(schema: schema)
                    .persist(messageState.stored, persistedCreatedAt: messageState.persistedCreatedAt, sql: sql)
            }
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: table("fanout_sync_payloads"))
                    (source_event_id, projection_kind, payload, message_state_id, created_at)
                VALUES (\(bind: sourceEventID), \(bind: input.projectionKind),
                        CASE
                            WHEN \(bind: payloadWriteMode == .reference)
                             AND \(bind: input.messageState?.payloadJSON)::jsonb =
                                 \(bind: input.eventPayloadJSON)::jsonb
                            THEN NULL
                            ELSE \(bind: input.eventPayloadJSON)::jsonb
                        END,
                        \(bind: input.messageState?.stateID), \(bind: now))
                ON CONFLICT (source_event_id, projection_kind) DO UPDATE
                SET message_state_id = COALESCE(
                    \(unsafeRaw: table("fanout_sync_payloads")).message_state_id,
                    EXCLUDED.message_state_id
                ),
                    payload = CASE
                        WHEN EXCLUDED.payload IS NULL
                         AND \(unsafeRaw: table("fanout_sync_payloads")).message_state_id = EXCLUDED.message_state_id
                        THEN NULL
                        ELSE \(unsafeRaw: table("fanout_sync_payloads")).payload
                    END
                WHERE EXCLUDED.message_state_id IS NOT NULL
                  AND (
                      \(unsafeRaw: table("fanout_sync_payloads")).message_state_id IS NULL
                      OR (
                          EXCLUDED.payload IS NULL
                          AND \(unsafeRaw: table("fanout_sync_payloads")).payload IS NOT NULL
                          AND \(unsafeRaw: table("fanout_sync_payloads")).message_state_id = EXCLUDED.message_state_id
                      )
                  )
                """).run()
            guard let shared = try await sql.raw("""
                SELECT 1 AS value
                FROM \(unsafeRaw: table("fanout_sync_payloads")) AS shared
                LEFT JOIN \(unsafeRaw: table("message_projection_state_values")) AS state
                  ON state.state_id = shared.message_state_id
                WHERE shared.source_event_id = \(bind: sourceEventID)
                  AND shared.projection_kind = \(bind: input.projectionKind)
                  AND COALESCE(shared.payload, state.payload) = \(bind: input.eventPayloadJSON)::jsonb
                  AND shared.message_state_id IS NOT DISTINCT FROM \(bind: input.messageState?.stateID)
                """).first(decoding: CrossStoreExistsRow.self), shared.value == 1 else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: table("user_sync_log"))
                    (user_id, user_sync_sequence, source_event_id, projection_kind, payload, payload_storage, created_at)
                VALUES (
                    \(bind: targetUserID), \(bind: sequence.userSyncSequence), \(bind: sourceEventID), \(bind: input.projectionKind),
                    NULL, 'fanout_shared',
                    \(bind: now)
                )
                """).run()
            try await sql.raw("""
                UPDATE \(unsafeRaw: table("consumer_inbox"))
                SET user_sync_sequence = \(bind: sequence.userSyncSequence)
                WHERE consumer_name = \(bind: consumerName)
                  AND source_event_id = \(bind: sourceEventID)
                  AND target_user_id = \(bind: targetUserID)
                  AND projection_kind = \(bind: input.projectionKind)
                """).run()
            return try crossStoreUnsigned(sequence.userSyncSequence)
        }
    }

    /// 在单个目标存储事务中投影一个有界的同物理分片批次。
    ///
    /// 控制存储的完成刻意留在该事务之外：PostgreSQL 无法跨两个数据库原子提交。
    /// 若进程在本目标事务提交后中止，重试会读取下方由收件箱支撑的同步序号，
    /// 只补完仍被围栏保护的控制投递。重复的不可变事件载荷通过单独的、
    /// 去重后的表发送：普通房间事件批次中多个目标行共享一份载荷，
    /// 若按目标重复发送，会无谓消耗网络、JSON 解析与 PostgreSQL 内存。
    ///
    /// - Parameters:
    ///   - inputs: 本批次待投影的扇出输入，顺序决定返回序号的顺序。
    ///   - now: 本次批次统一使用的提交时间戳。
    /// - Returns: 与 `inputs` 一一对应、按同一顺序排列的用户同步序号。
    /// - Throws: 时间戳无法编码、标识符非法或持久化状态损坏时抛出。
    public func projectBatch(_ inputs: [V2FanoutProjectionInput], now: Date) async throws -> [UInt64] {
        guard !inputs.isEmpty else { return [] }
        guard v2PostgresTimestampCanEncode(now) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        var payloadIndexes: [String: Int] = [:]
        var uniquePayloads: [String] = []
        var messageStatesByID: [UUID: V2FanoutMessageProjectionState] = [:]
        let encoded = try inputs.enumerated().map { index, input in
            guard let sourceEventID = UUID(uuidString: input.sourceEventID.rawValue),
                  let targetUserID = UUID(uuidString: input.targetUserID.rawValue)
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let payloadIndex: Int
            if let existing = payloadIndexes[input.eventPayloadJSON] {
                payloadIndex = existing
            } else {
                payloadIndex = uniquePayloads.count
                uniquePayloads.append(input.eventPayloadJSON)
                payloadIndexes[input.eventPayloadJSON] = payloadIndex
            }
            if let messageState = input.messageState {
                guard input.projectionKind == "message" else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                if let existing = messageStatesByID[messageState.stateID], existing != messageState {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                messageStatesByID[messageState.stateID] = messageState
            }
            return CrossStoreBatchProjectionInput(
                ordinal: index, sourceEventID: sourceEventID, targetUserID: targetUserID,
                projectionKind: input.projectionKind, payloadIndex: payloadIndex,
                messageStateID: input.messageState?.stateID
            )
        }
        let identities = encoded.map {
            "\($0.sourceEventID.uuidString)|\($0.targetUserID.uuidString)|\($0.projectionKind)"
        }
        guard Set(identities).count == encoded.count else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        var sharedIdentities: [String: (payloadIndex: Int, stateID: UUID?)] = [:]
        for item in encoded {
            let key = "\(item.sourceEventID.uuidString)|\(item.projectionKind)"
            if let existing = sharedIdentities[key] {
                guard existing.payloadIndex == item.payloadIndex,
                      existing.stateID == item.messageStateID
                else { throw V2RoomWriteStoreError.corruptPersistenceState }
            } else {
                sharedIdentities[key] = (item.payloadIndex, item.messageStateID)
            }
        }
        let inputJSON = try crossStoreBatchJSON(encoded)
        let payloadJSON = try crossStoreBatchJSON(uniquePayloads)
        let messageStateJSON = try crossStoreBatchJSON(
            messageStatesByID.values.sorted { $0.stateID.uuidString < $1.stateID.uuidString }
                .map { try CrossStoreMessageStateInput($0) }
        )
        let expectedMessageStateCount = Int64(messageStatesByID.count)
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: table("message_projection_states"))
                    (state_id, message_id, room_id, message_revision, variant_key,
                     origin_event_id, state_event_id, is_withdrawn,
                     payload_schema_version, payload, created_at)
                SELECT state_id, message_id, room_id, message_revision, variant_key,
                       origin_event_id, state_event_id, is_withdrawn,
                       payload_schema_version, payload_json::jsonb,
                       (TIMESTAMP '2000-01-01 00:00:00'
                         + (created_at_postgres_microseconds / 86400000000) * INTERVAL '1 day'
                         + (created_at_postgres_microseconds % 86400000000) * INTERVAL '1 microsecond')
                         AT TIME ZONE 'UTC'
                FROM jsonb_to_recordset(\(bind: messageStateJSON)::jsonb) AS value(
                    state_id uuid, message_id uuid, room_id uuid,
                    message_revision bigint, variant_key smallint,
                    origin_event_id uuid, state_event_id uuid,
                    is_withdrawn boolean, payload_schema_version smallint,
                    payload_json text, created_at_postgres_microseconds bigint
                )
                ON CONFLICT DO NOTHING
                """).run()
            // Match the scalar repository's canonical-content fence. The
            // first persisted creation time remains unchanged; it is not part
            // of state identity. Older batches used Unix-epoch flooring and
            // may differ by a microsecond from the native Date representation.
            guard let stateVerification = try await sql.raw("""
                SELECT COUNT(*)::bigint AS value
                FROM jsonb_to_recordset(\(bind: messageStateJSON)::jsonb) AS value(
                    state_id uuid, message_id uuid, room_id uuid,
                    message_revision bigint, variant_key smallint,
                    origin_event_id uuid, state_event_id uuid,
                    is_withdrawn boolean, payload_schema_version smallint,
                    payload_json text, created_at_postgres_microseconds bigint
                )
                JOIN \(unsafeRaw: table("message_projection_state_values")) AS stored
                  ON stored.state_id = value.state_id
                 AND stored.message_id = value.message_id
                 AND stored.room_id = value.room_id
                 AND stored.message_revision = value.message_revision
                 AND stored.variant_key = value.variant_key
                 AND stored.origin_event_id = value.origin_event_id
                 AND stored.state_event_id IS NOT DISTINCT FROM value.state_event_id
                 AND stored.is_withdrawn = value.is_withdrawn
                 AND stored.payload_schema_version = value.payload_schema_version
                 AND stored.payload = value.payload_json::jsonb
                """).first(decoding: CrossStoreCountRow.self),
                  stateVerification.value == expectedMessageStateCount
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            // Persist first, then validate from the next statement's snapshot.
            // This avoids both sibling-CTE visibility gaps and no-op UPDATE
            // locks when batches for the same event run concurrently.
            try await sql.raw("""
                WITH payloads AS MATERIALIZED (
                    SELECT (ordinality - 1)::integer AS payload_index,
                           value::jsonb AS event_payload
                    FROM jsonb_array_elements_text(\(bind: payloadJSON)::jsonb)
                         WITH ORDINALITY AS payload(value, ordinality)
                ), input AS (
                    SELECT value.source_event_id, value.projection_kind,
                           value.message_state_id, payload.event_payload
                    FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb) AS value(
                        ordinal integer, source_event_id uuid, target_user_id uuid,
                        projection_kind text, payload_index integer, message_state_id uuid
                    )
                    JOIN payloads AS payload ON payload.payload_index = value.payload_index
                ), payload_keys AS MATERIALIZED (
                    SELECT DISTINCT source_event_id, projection_kind,
                                    message_state_id, event_payload FROM input
                )
                INSERT INTO \(unsafeRaw: table("fanout_sync_payloads"))
                    (source_event_id, projection_kind, payload, message_state_id, created_at)
                SELECT payload.source_event_id, payload.projection_kind,
                       CASE WHEN \(bind: payloadWriteMode == .reference)
                                      AND state.payload = payload.event_payload
                            THEN NULL ELSE payload.event_payload END,
                       payload.message_state_id, \(bind: now)
                FROM payload_keys AS payload
                LEFT JOIN \(unsafeRaw: table("message_projection_state_values")) AS state
                  ON state.state_id = payload.message_state_id
                ON CONFLICT (source_event_id, projection_kind) DO UPDATE
                SET message_state_id = COALESCE(
                    \(unsafeRaw: table("fanout_sync_payloads")).message_state_id,
                    EXCLUDED.message_state_id
                ),
                    payload = CASE
                        WHEN EXCLUDED.payload IS NULL
                         AND \(unsafeRaw: table("fanout_sync_payloads")).message_state_id = EXCLUDED.message_state_id
                        THEN NULL
                        ELSE \(unsafeRaw: table("fanout_sync_payloads")).payload
                    END
                WHERE EXCLUDED.message_state_id IS NOT NULL
                  AND (
                      \(unsafeRaw: table("fanout_sync_payloads")).message_state_id IS NULL
                      OR (
                          EXCLUDED.payload IS NULL
                          AND \(unsafeRaw: table("fanout_sync_payloads")).payload IS NOT NULL
                          AND \(unsafeRaw: table("fanout_sync_payloads")).message_state_id = EXCLUDED.message_state_id
                      )
                  )
                """).run()
            // As on the colocated path, make inbox fences visible to the next
            // statement before allocating sequences. A data-modifying CTE
            // cannot update a sibling CTE's newly inserted row through the
            // table snapshot on PostgreSQL.
            try await sql.raw("""
                WITH input AS (
                    SELECT source_event_id, target_user_id, projection_kind
                    FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb) AS value(
                        ordinal integer, source_event_id uuid, target_user_id uuid,
                        projection_kind text, payload_index integer
                    )
                )
                INSERT INTO \(unsafeRaw: table("consumer_inbox"))
                    (consumer_name, source_event_id, target_user_id,
                     projection_kind, committed_at)
                SELECT \(bind: consumerName), source_event_id, target_user_id,
                       projection_kind, \(bind: now)
                FROM input
                ON CONFLICT DO NOTHING
                """).run()
            let rows = try await sql.raw("""
                WITH payloads AS MATERIALIZED (
                    SELECT (ordinality - 1)::integer AS payload_index,
                           value::jsonb AS event_payload
                    FROM jsonb_array_elements_text(\(bind: payloadJSON)::jsonb)
                         WITH ORDINALITY AS payload(value, ordinality)
                ), input AS (
                    SELECT value.ordinal, value.source_event_id, value.target_user_id,
                           value.projection_kind, value.message_state_id,
                           payload.event_payload
                    FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb) AS value(
                        ordinal integer, source_event_id uuid, target_user_id uuid,
                        projection_kind text, payload_index integer, message_state_id uuid
                    )
                    JOIN payloads AS payload ON payload.payload_index = value.payload_index
                ), payload_keys AS MATERIALIZED (
                    SELECT DISTINCT source_event_id, projection_kind,
                                    message_state_id, event_payload
                    FROM input
                ), verified_payloads AS MATERIALIZED (
                    SELECT payload_keys.source_event_id, payload_keys.projection_kind
                    FROM payload_keys
                    JOIN \(unsafeRaw: table("fanout_sync_payloads")) AS shared
                     ON shared.source_event_id = payload_keys.source_event_id
                     AND shared.projection_kind = payload_keys.projection_kind
                     AND shared.message_state_id IS NOT DISTINCT FROM payload_keys.message_state_id
                    LEFT JOIN \(unsafeRaw: table("message_projection_state_values")) AS state
                      ON state.state_id = shared.message_state_id
                    WHERE COALESCE(shared.payload, state.payload) = payload_keys.event_payload
                ), pending_inbox AS MATERIALIZED (
                    SELECT inbox.source_event_id, inbox.target_user_id,
                           inbox.projection_kind
                    FROM \(unsafeRaw: table("consumer_inbox")) AS inbox
                    JOIN input
                      USING (source_event_id, target_user_id, projection_kind)
                    WHERE inbox.consumer_name = \(bind: consumerName)
                      AND inbox.user_sync_sequence IS NULL
                ), per_user AS (
                    SELECT target_user_id AS user_id, COUNT(*)::bigint AS sequence_count
                    FROM pending_inbox
                    GROUP BY target_user_id
                ), reserved_sequence AS (
                    INSERT INTO \(unsafeRaw: table("user_sync_sequences")) AS sequence (user_id, next_sequence)
                    SELECT user_id, sequence_count
                    FROM per_user
                    ORDER BY user_id
                    ON CONFLICT (user_id)
                    DO UPDATE SET next_sequence = sequence.next_sequence + EXCLUDED.next_sequence
                    WHERE sequence.next_sequence <= \(bind: Int64.max) - EXCLUDED.next_sequence
                    RETURNING user_id, next_sequence
                ), numbered AS (
                    SELECT input.ordinal, input.source_event_id, input.target_user_id,
                           input.projection_kind, input.event_payload,
                           reserved_sequence.next_sequence - per_user.sequence_count
                             + ROW_NUMBER() OVER (
                                 PARTITION BY input.target_user_id
                                 ORDER BY input.source_event_id, input.target_user_id, input.projection_kind
                               ) AS user_sync_sequence
                    FROM input
                    JOIN pending_inbox
                      USING (source_event_id, target_user_id, projection_kind)
                    JOIN per_user ON per_user.user_id = input.target_user_id
                    JOIN reserved_sequence ON reserved_sequence.user_id = input.target_user_id
                ), inserted_log AS (
                    INSERT INTO \(unsafeRaw: table("user_sync_log"))
                        (user_id, user_sync_sequence, source_event_id, projection_kind, payload, payload_storage, created_at)
                    SELECT target_user_id, user_sync_sequence, source_event_id, projection_kind,
                           NULL, 'fanout_shared',
                           \(bind: now)
                    FROM numbered
                    JOIN verified_payloads
                      USING (source_event_id, projection_kind)
                    RETURNING user_id, user_sync_sequence, source_event_id, projection_kind
                ), recorded_inbox AS (
                    UPDATE \(unsafeRaw: table("consumer_inbox")) AS inbox
                    SET user_sync_sequence = inserted_log.user_sync_sequence
                    FROM inserted_log
                    WHERE inbox.consumer_name = \(bind: consumerName)
                      AND inbox.source_event_id = inserted_log.source_event_id
                      AND inbox.target_user_id = inserted_log.user_id
                      AND inbox.projection_kind = inserted_log.projection_kind
                    RETURNING inbox.source_event_id, inbox.target_user_id,
                              inbox.projection_kind, inbox.user_sync_sequence
                ), inserted_outcomes AS (
                    SELECT numbered.ordinal, recorded_inbox.user_sync_sequence
                    FROM numbered
                    JOIN recorded_inbox
                      ON recorded_inbox.target_user_id = numbered.target_user_id
                     AND recorded_inbox.user_sync_sequence = numbered.user_sync_sequence
                     AND recorded_inbox.source_event_id = numbered.source_event_id
                     AND recorded_inbox.projection_kind = numbered.projection_kind
                ), conflict_input AS (
                    SELECT input.ordinal, input.source_event_id, input.target_user_id, input.projection_kind
                    FROM input
                    LEFT JOIN pending_inbox
                      USING (source_event_id, target_user_id, projection_kind)
                    WHERE pending_inbox.source_event_id IS NULL
                ), conflict_outcomes AS (
                    SELECT conflict.ordinal, inbox.user_sync_sequence
                    FROM conflict_input AS conflict
                    JOIN \(unsafeRaw: table("consumer_inbox")) AS inbox
                      ON inbox.consumer_name = \(bind: consumerName)
                     AND inbox.target_user_id = conflict.target_user_id
                     AND inbox.source_event_id = conflict.source_event_id
                     AND inbox.projection_kind = conflict.projection_kind
                     AND inbox.user_sync_sequence IS NOT NULL
                )
                SELECT ordinal, user_sync_sequence
                FROM inserted_outcomes
                UNION ALL
                SELECT ordinal, user_sync_sequence
                FROM conflict_outcomes
                ORDER BY ordinal
                """).all(decoding: CrossStoreBatchProjectionOutcomeRow.self)
            // Missing allocations include exhausted sequence ranges. Roll back
            // all new inbox/log writes instead of returning a partial batch.
            guard rows.count == inputs.count else { throw V2RoomWriteStoreError.corruptPersistenceState }
            var sequences = Array<UInt64?>(repeating: nil, count: inputs.count)
            for row in rows {
                guard sequences.indices.contains(row.ordinal), sequences[row.ordinal] == nil else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                sequences[row.ordinal] = try crossStoreUnsigned(row.userSyncSequence)
            }
            guard sequences.allSatisfy({ $0 != nil }) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            return sequences.map { $0! }
        }
    }

    /// 镜像一条源端拥有的同步记录且不改变其序号。
    ///
    /// 它首先使用语义身份 `(user, source event, kind)`；若某序号与另一条不同记录
    /// 冲突，则视为持久化损坏，而非迁移期间可覆盖的冲突。
    ///
    /// - Parameter record: 待镜像的、已提交的用户同步记录。
    /// - Returns: 与源记录一致的持久化用户同步序号。
    /// - Throws: 标识符非法、序号超出可编码范围或持久化状态损坏时抛出。
    public func mirror(_ record: V2UserSyncProjectionMirror) async throws -> UInt64 {
        try await mirror(record, persistedCreatedAt: nil)
    }

    func mirror(
        _ record: V2UserSyncProjectionMirror,
        persistedCreatedAt: V2PostgresTimestamp?
    ) async throws -> UInt64 {
        guard let userID = UUID(uuidString: record.userID.rawValue),
              let sourceEventID = UUID(uuidString: record.sourceEventID.rawValue),
              let sequence = Int64(exactly: record.sequence), sequence > 0
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            if let existing = try await sql.raw("""
                SELECT user_sync_sequence, payload::text AS payload_json
                FROM \(unsafeRaw: table("user_projection_effects"))
                WHERE user_id = \(bind: userID) AND source_event_id = \(bind: sourceEventID)
                  AND projection_kind = \(bind: record.projectionKind)
                """).first(decoding: CrossStoreMirroredRecordRow.self) {
                guard existing.userSyncSequence == sequence, existing.payloadJSON == record.payloadJSON else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                return try crossStoreUnsigned(existing.userSyncSequence)
            }
            let createdAt = try persistedCreatedAt ?? V2PostgresTimestamp(date: record.createdAt)
            if let occupying = try await sql.raw("""
                SELECT source_event_id, projection_kind
                FROM \(unsafeRaw: table("user_sync_log"))
                WHERE user_id = \(bind: userID) AND user_sync_sequence = \(bind: sequence)
                """).first(decoding: CrossStoreSequenceOccupantRow.self),
               occupying.sourceEventID != sourceEventID || occupying.projectionKind != record.projectionKind {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: table("user_sync_sequences")) (user_id, next_sequence)
                VALUES (\(bind: userID), \(bind: sequence))
                ON CONFLICT (user_id) DO UPDATE
                SET next_sequence = GREATEST(\(unsafeRaw: table("user_sync_sequences")).next_sequence, EXCLUDED.next_sequence)
                """).run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: table("user_sync_log"))
                    (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at)
                VALUES (\(bind: userID), \(bind: sequence), \(bind: sourceEventID), \(bind: record.projectionKind),
                        \(bind: record.payloadJSON)::jsonb, \(bind: createdAt))
                ON CONFLICT DO NOTHING
                """).run()
            // The ordered row may already have been compacted after a prior
            // successful mirror. The stable semantic result is the durable
            // source for exact retry validation in either case.
            guard let mirrored = try await sql.raw("""
                SELECT user_sync_sequence, payload::text AS payload_json
                FROM \(unsafeRaw: table("user_projection_effects"))
                WHERE user_id = \(bind: userID) AND source_event_id = \(bind: sourceEventID)
                  AND projection_kind = \(bind: record.projectionKind)
                """).first(decoding: CrossStoreMirroredRecordRow.self),
                  mirrored.userSyncSequence == sequence, mirrored.payloadJSON == record.payloadJSON
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            return try crossStoreUnsigned(mirrored.userSyncSequence)
        }
    }

    /// 把控制面拥有的投影追加到当前权威的用户分片。
    ///
    /// 其源事件/类型身份使重试具备幂等性，而序号由该分片分配。
    /// 切换后这是必需的：控制数据库的历史计数器不再是目标用户的实时序号计数器。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - sourceEventID: 源事件标识。
    ///   - projectionKind: 投影类型。
    ///   - payloadJSON: 投影载荷 JSON。
    ///   - createdAt: 投影创建时间。
    /// - Returns: 由目标用户分片新分配的用户同步序号。
    /// - Throws: 标识符非法、时间戳无法编码或持久化状态损坏时抛出。
    public func projectAllocated(
        userID: UserID,
        sourceEventID: EventID,
        projectionKind: String,
        payloadJSON: String,
        createdAt: Date
    ) async throws -> UInt64 {
        try await projectAllocated(userID: userID, sourceEventID: sourceEventID,
            projectionKind: projectionKind, payloadJSON: payloadJSON, createdAt: createdAt, persistedCreatedAt: nil)
    }

    func projectAllocated(
        userID: UserID,
        sourceEventID: EventID,
        projectionKind: String,
        payloadJSON: String,
        createdAt: Date,
        persistedCreatedAt: V2PostgresTimestamp?
    ) async throws -> UInt64 {
        guard let userUUID = UUID(uuidString: userID.rawValue),
              let eventUUID = UUID(uuidString: sourceEventID.rawValue)
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            if let existing = try await sql.raw("""
                SELECT user_sync_sequence, payload::text AS payload_json
                FROM \(unsafeRaw: table("user_projection_effects"))
                WHERE user_id = \(bind: userUUID) AND source_event_id = \(bind: eventUUID)
                  AND projection_kind = \(bind: projectionKind)
                """).first(decoding: CrossStoreMirroredRecordRow.self) {
                guard existing.payloadJSON == payloadJSON else { throw V2RoomWriteStoreError.corruptPersistenceState }
                return try crossStoreUnsigned(existing.userSyncSequence)
            }
            let timestamp = try persistedCreatedAt ?? V2PostgresTimestamp(date: createdAt)
            guard let sequence = try await sql.raw("""
                INSERT INTO \(unsafeRaw: table("user_sync_sequences")) (user_id, next_sequence)
                VALUES (\(bind: userUUID), 1)
                ON CONFLICT (user_id)
                DO UPDATE SET next_sequence = \(unsafeRaw: table("user_sync_sequences")).next_sequence + 1
                WHERE \(unsafeRaw: table("user_sync_sequences")).next_sequence < \(bind: Int64.max)
                RETURNING next_sequence AS user_sync_sequence
                """).first(decoding: CrossStoreSequenceRow.self)
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: table("user_sync_log"))
                    (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at)
                VALUES (\(bind: userUUID), \(bind: sequence.userSyncSequence), \(bind: eventUUID), \(bind: projectionKind),
                        \(bind: payloadJSON)::jsonb, \(bind: timestamp))
                """).run()
            return try crossStoreUnsigned(sequence.userSyncSequence)
        }
    }

    private func table(_ name: String) -> String { "\(schema).\(name)" }
}

/// 将扇出控制记录保留在其权威数据库中，同时按持久逻辑路由选定的物理存储
/// 物化每用户投影。
///
/// 所有租约/重试/交接操作仍是控制存储操作；只有用户投影跨存储。
public struct V2CrossStoreFanoutDeliveryStore:
    V2PartitionedFanoutDeliveryStore,
    V2FreshDirectFanoutDeliveryStore,
    Sendable
{
    private let control: PostgresV2FanoutDeliveryStore
    private let registry: any V2UserShardStorageResolving
    private let migrations: PostgresV2UserShardMigrationStore
    /// 仅由组合根在确认该桶使用控制数据库的 `im_v2` schema 后设置。
    ///
    /// 它刻意是拓扑数据，而不是对数据库对象做尽力而为的比较。
    private let coLocatedControlBucket: String?
    /// 超过该大小的载荷会在租约认领结果中按源事件返回一次。
    ///
    /// 其余已认领租约在任何目标事务开始前，从进程本地副本完成。
    /// 这样可避免一个大体积不可变房间事件演变成随成员数放大的控制响应，
    /// 同时无需增加第二次控制存储读取。
    private let maximumInlineClaimPayloadBytes: Int
    private let payloadWriteMode: V2FanoutPayloadWriteMode
    private let timingRecorder: (any V2CrossStoreFanoutDeliveryTimingRecording)?

    /// 远端用户分片的目标事务与控制完成是两个有序的数据库边界。
    ///
    /// 同一远端桶的多个认领工作协程会以 `SKIP LOCKED` 分割认领，并在完成单元上竞争；
    /// 隔离的 5k 档位在四个此类工作协程下出现回退。
    /// 同置桶保留并行投影，但将单个物理 PostgreSQL 分片限制在实测的八次认领轮次：
    /// 十六次会徒增锁与认领开销，而在 80k 档位并不降低端到端延迟。
    public var maximumConcurrentClaimsPerBucket: Int {
        coLocatedControlBucket == nil ? 1 : 8
    }

    public init(
        control: PostgresV2FanoutDeliveryStore,
        registry: any V2UserShardStorageResolving,
        migrations: PostgresV2UserShardMigrationStore,
        coLocatedControlBucket: String? = nil,
        maximumInlineClaimPayloadBytes: Int = 1_024,
        payloadWriteMode: V2FanoutPayloadWriteMode = .body,
        timingRecorder: (any V2CrossStoreFanoutDeliveryTimingRecording)? = nil
    ) {
        precondition(maximumInlineClaimPayloadBytes > 0)
        self.control = control
        self.registry = registry
        self.migrations = migrations
        self.coLocatedControlBucket = coLocatedControlBucket
        self.maximumInlineClaimPayloadBytes = maximumInlineClaimPayloadBytes
        self.payloadWriteMode = payloadWriteMode
        self.timingRecorder = timingRecorder
    }

    public func claimPending(bucket: String?, lane: V2FanoutDeliveryClaimLane, now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2FanoutDeliveryLease] {
        try await claimPending(
            bucket: bucket, lane: lane, partition: nil,
            now: now, leaseDuration: leaseDuration, limit: limit
        )
    }

    public func claimPending(
        bucket: String?, lane: V2FanoutDeliveryClaimLane,
        partition: V2FanoutDeliveryClaimPartition,
        now: Date, leaseDuration: TimeInterval, limit: Int
    ) async throws -> [V2FanoutDeliveryLease] {
        try await claimPending(
            bucket: bucket, lane: lane, partition: Optional(partition),
            now: now, leaseDuration: leaseDuration, limit: limit
        )
    }

    private func claimPending(
        bucket: String?, lane: V2FanoutDeliveryClaimLane,
        partition: V2FanoutDeliveryClaimPartition?,
        now: Date, leaseDuration: TimeInterval, limit: Int
    ) async throws -> [V2FanoutDeliveryLease] {
        // A co-located target commits through `control.commitBatch`, which
        // reads the immutable payload inside that same control-database
        // transaction. Returning it from the claim would add a room-event
        // join, JSON serialization and process-memory copy that this path
        // never consumes. Remote targets retain the enriched claim because
        // their independent target transaction needs the source payload.
        if bucket == coLocatedControlBucket {
            if let partition {
                return try await control.claimPending(
                    bucket: bucket, lane: lane, partition: partition,
                    now: now, leaseDuration: leaseDuration, limit: limit
                )
            }
            return try await control.claimPending(
                bucket: bucket, lane: lane, now: now,
                leaseDuration: leaseDuration, limit: limit
            )
        }
        let leases = try await control.claimPendingIncludingProjectionPayload(
            bucket: bucket, lane: lane, now: now, leaseDuration: leaseDuration, limit: limit,
            maximumInlinePayloadBytes: maximumInlineClaimPayloadBytes,
            partition: partition
        )
        var payloadsBySourceEvent: [EventID: String] = [:]
        for lease in leases {
            guard let payload = lease.eventPayloadJSON else { continue }
            if let existing = payloadsBySourceEvent[lease.sourceEventID], existing != payload {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            payloadsBySourceEvent[lease.sourceEventID] = payload
        }
        guard leases.contains(where: { $0.eventPayloadJSON == nil }) else { return leases }

        // The claim query emits one copy of an oversized event payload per
        // source event. All rows share the same immutable source event, so
        // expanding that one value in memory preserves the fenced lease
        // semantics while avoiding an extra read (and its large CTE input).
        return try leases.map { lease in
            guard lease.eventPayloadJSON == nil else { return lease }
            guard let payload = payloadsBySourceEvent[lease.sourceEventID] else {
                // The room event is authoritative and must exist for every
                // delivery. A claim result with no source payload is therefore
                // persistence corruption, not a stale-lease condition.
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            return .init(
                sourceEventID: lease.sourceEventID, targetUserID: lease.targetUserID,
                projectionKind: lease.projectionKind, completionUnitID: lease.completionUnitID,
                observedRoute: lease.observedRoute, claimToken: lease.claimToken,
                attempt: lease.attempt, eventPayloadJSON: payload
            )
        }
    }

    public func commitFreshDirectPreplanned(
        bucket: String?, partition: V2FanoutDeliveryClaimPartition?,
        now: Date, limit: Int
    ) async throws -> [V2FreshDirectFanoutDeliveryCommit] {
        // The optimization is intentionally topology-gated. A remote target
        // still needs two durable transactions and therefore keeps the
        // established inbox + control acknowledgement protocol.
        guard let coLocatedControlBucket,
              bucket == coLocatedControlBucket
        else { return [] }
        return try await control.commitFreshDirectPreplanned(
            bucket: bucket, partition: partition, now: now, limit: limit
        )
    }

    public func claimFreshDirectPreplannedForRecovery(
        bucket: String?, partition: V2FanoutDeliveryClaimPartition?,
        now: Date, leaseDuration: TimeInterval, limit: Int
    ) async throws -> [V2FanoutDeliveryLease] {
        guard let coLocatedControlBucket,
              bucket == coLocatedControlBucket
        else { return [] }
        return try await control.claimFreshDirectPreplannedForRecovery(
            bucket: bucket, partition: partition, now: now,
            leaseDuration: leaseDuration, limit: limit
        )
    }

    public func commit(_ lease: V2FanoutDeliveryLease, now: Date) async throws -> V2FanoutDeliveryCommit {
        let input: V2FanoutProjectionInput
        if lease.projectionKind == "message" {
            guard let fencedInput = try await control.projectionInput(for: lease) else { return .staleLease }
            input = fencedInput
        } else if let payload = lease.eventPayloadJSON {
            input = .init(
                sourceEventID: lease.sourceEventID, targetUserID: lease.targetUserID,
                projectionKind: lease.projectionKind, eventPayloadJSON: payload
            )
        } else {
            guard let fencedInput = try await control.projectionInput(for: lease) else { return .staleLease }
            input = fencedInput
        }
        let location = try registry.location(for: lease.observedRoute.bucket)
        let sequence = try await PostgresV2UserShardFanoutProjector(
            database: location.database, schema: location.schema,
            payloadWriteMode: payloadWriteMode
        ).project(input, now: now)
        let migration = try await migrations.load(userID: lease.targetUserID)
        if requiresForwardingShadow(for: lease, migration: migration) {
            guard let migration else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let shadow = try registry.location(for: migration.targetBucket)
            _ = try await PostgresV2UserShardFanoutProjector(
                database: shadow.database, schema: shadow.schema,
                payloadWriteMode: payloadWriteMode
            ).project(input, now: now)
        }
        return try await control.completeExternal(lease, userSyncSequence: sequence, now: now)
    }

    /// 仅当部署拓扑证明所有投影都位于同一 `im_v2` schema 且无需转发/已校验移动的影子写入时，
    /// 才使用控制存储原生的原子批次。
    ///
    /// 对于外部桶，目标收件箱/序号/日志效果改为在该单一物理用户数据库中批量执行；
    /// 随后每个成功的目标序号通过其独立的控制存储租约围栏完成。
    /// 转发中的用户刻意保留既有的逐目标协议，因为它还需要第二个迁移目标投影。
    ///
    /// - Parameters:
    ///   - leases: 本批次待提交的扇出投递租约，顺序决定返回结果的顺序。
    ///   - now: 本次提交统一使用的时间戳。
    /// - Returns: 与 `leases` 一一对应、按同一顺序排列的提交结果。
    /// - Throws: 路由缺失、标识符非法或持久化状态损坏时抛出。
    public func commitBatch(_ leases: [V2FanoutDeliveryLease], now: Date) async throws -> [V2FanoutDeliveryCommit] {
        guard !leases.isEmpty else { return [] }
        if try await canCommitAtomicallyInControlStore(leases) {
            return try await control.commitBatchFencedToCurrentRoutes(leases, now: now)
        }
        var results = Array<V2FanoutDeliveryCommit?>(repeating: nil, count: leases.count)
        let grouped = Dictionary(grouping: leases.enumerated(), by: { $0.element.observedRoute.bucket })
        for bucket in grouped.keys.sorted() {
            guard let items = grouped[bucket] else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let batchStartedAt = ContinuousClock.now
            let location = try registry.location(for: bucket)
            let migrationReadStartedAt = ContinuousClock.now
            let migrationRecords = try await migrations.load(userIDs: Array(Set(items.map(\.element.targetUserID))).sorted())
            let migrationReadMilliseconds = v2CrossStoreElapsedMilliseconds(migrationReadStartedAt.duration(to: .now))
            var batch: [(index: Int, lease: V2FanoutDeliveryLease, input: V2FanoutProjectionInput)] = []
            var candidates: [(index: Int, lease: V2FanoutDeliveryLease)] = []
            var fallback: [(index: Int, lease: V2FanoutDeliveryLease)] = []
            for (index, lease) in items {
                if requiresForwardingShadow(for: lease, migration: migrationRecords[lease.targetUserID]) {
                    fallback.append((index, lease))
                    continue
                }
                candidates.append((index, lease))
            }
            for candidate in candidates
                where candidate.lease.projectionKind != "message"
                    && candidate.lease.eventPayloadJSON != nil
            {
                guard let payload = candidate.lease.eventPayloadJSON else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                batch.append((
                    candidate.index, candidate.lease,
                    .init(
                        sourceEventID: candidate.lease.sourceEventID, targetUserID: candidate.lease.targetUserID,
                        projectionKind: candidate.lease.projectionKind, eventPayloadJSON: payload
                    )
                ))
            }
            let payloadReadCandidates = candidates.filter {
                $0.lease.projectionKind == "message" || $0.lease.eventPayloadJSON == nil
            }
            if !payloadReadCandidates.isEmpty {
                let inputs = try await control.projectionInputs(for: payloadReadCandidates.map(\.lease))
                guard inputs.count == payloadReadCandidates.count else { throw V2RoomWriteStoreError.corruptPersistenceState }
                for (candidate, input) in zip(payloadReadCandidates, inputs) {
                    guard let input else {
                        results[candidate.index] = .staleLease
                        continue
                    }
                    batch.append((candidate.index, candidate.lease, input))
                }
            }
            if !batch.isEmpty {
                let projector = try PostgresV2UserShardFanoutProjector(
                    database: location.database, schema: location.schema,
                    payloadWriteMode: payloadWriteMode
                )
                let targetProjectionStartedAt = ContinuousClock.now
                let sequences = try await projector.projectBatch(batch.map(\.input), now: now)
                let targetProjectionMilliseconds = v2CrossStoreElapsedMilliseconds(targetProjectionStartedAt.duration(to: .now))
                guard sequences.count == batch.count else { throw V2RoomWriteStoreError.corruptPersistenceState }
                let acknowledgements = zip(batch, sequences).map {
                    V2ExternalFanoutDeliveryAcknowledgement(lease: $0.lease, userSyncSequence: $1)
                }
                let controlCompletionStartedAt = ContinuousClock.now
                let completions = try await control.completeExternalBatch(acknowledgements, now: now)
                let controlCompletionMilliseconds = v2CrossStoreElapsedMilliseconds(controlCompletionStartedAt.duration(to: .now))
                guard completions.count == batch.count else { throw V2RoomWriteStoreError.corruptPersistenceState }
                for (item, completion) in zip(batch, completions) {
                    results[item.index] = completion
                }
                await timingRecorder?.record(.init(
                    targetCount: batch.count,
                    migrationReadMilliseconds: migrationReadMilliseconds,
                    targetProjectionMilliseconds: targetProjectionMilliseconds,
                    controlCompletionMilliseconds: controlCompletionMilliseconds,
                    totalMilliseconds: v2CrossStoreElapsedMilliseconds(batchStartedAt.duration(to: .now))
                ))
            }
            for item in fallback {
                results[item.index] = try await commit(item.lease, now: now)
            }
        }
        guard results.allSatisfy({ $0 != nil }) else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return results.map { $0! }
    }

    public func handoff(_ lease: V2FanoutDeliveryLease, to route: V2UserShardRoute) async throws {
        try await control.handoff(lease, to: route)
    }

    public func release(_ lease: V2FanoutDeliveryLease) async throws { try await control.release(lease) }

    public func scheduleRetry(_ lease: V2FanoutDeliveryLease, disposition: V2DurableRetryDisposition, now: Date) async throws {
        try await control.scheduleRetry(lease, disposition: disposition, now: now)
    }

    private func canCommitAtomicallyInControlStore(_ leases: [V2FanoutDeliveryLease]) async throws -> Bool {
        guard let coLocatedControlBucket else { return false }
        guard leases.allSatisfy({ $0.observedRoute.bucket == coLocatedControlBucket }) else { return false }
        let migrationRecords = try await migrations.load(userIDs: Array(Set(leases.map(\.targetUserID))).sorted())
        for lease in leases {
            if requiresForwardingShadow(for: lease, migration: migrationRecords[lease.targetUserID]) {
                return false
            }
        }
        return true
    }

    private func requiresForwardingShadow(
        for lease: V2FanoutDeliveryLease, migration: V2UserShardMigrationRecord?
    ) -> Bool {
        guard let migration else { return false }
        return (migration.phase == .forwarding || migration.phase == .verified)
            && migration.sourceBucket == lease.observedRoute.bucket
    }
}

extension V2CrossStoreFanoutDeliveryStore: V2FanoutDeliveryBucketConcurrencyControlling {}

private struct CrossStoreBatchProjectionInput: Encodable {
    let ordinal: Int
    let sourceEventID: UUID
    let targetUserID: UUID
    let projectionKind: String
    let payloadIndex: Int
    let messageStateID: UUID?

    enum CodingKeys: String, CodingKey {
        case ordinal
        case sourceEventID = "source_event_id"
        case targetUserID = "target_user_id"
        case projectionKind = "projection_kind"
        case payloadIndex = "payload_index"
        case messageStateID = "message_state_id"
    }
}
private struct CrossStoreMessageStateInput: Encodable {
    let stateID: UUID
    let messageID: UUID
    let roomID: UUID
    let messageRevision: Int64
    let variantKey: Int16
    let originEventID: UUID
    let stateEventID: UUID?
    let isWithdrawn: Bool
    let payloadSchemaVersion: Int16
    let payloadJSON: String
    let createdAtPostgresMicroseconds: Int64

    init(_ value: V2FanoutMessageProjectionState) throws {
        let timestamp = try value.persistedCreatedAt ?? V2PostgresTimestamp(date: value.createdAt)
        stateID = value.stateID
        messageID = value.messageID
        roomID = value.roomID
        messageRevision = value.messageRevision
        variantKey = value.variantKey
        originEventID = value.originEventID
        stateEventID = value.stateEventID
        isWithdrawn = value.isWithdrawn
        payloadSchemaVersion = value.payloadSchemaVersion
        payloadJSON = value.payloadJSON
        createdAtPostgresMicroseconds = timestamp.microseconds
    }

    private enum CodingKeys: String, CodingKey {
        case stateID = "state_id"
        case messageID = "message_id"
        case roomID = "room_id"
        case messageRevision = "message_revision"
        case variantKey = "variant_key"
        case originEventID = "origin_event_id"
        case stateEventID = "state_event_id"
        case isWithdrawn = "is_withdrawn"
        case payloadSchemaVersion = "payload_schema_version"
        case payloadJSON = "payload_json"
        case createdAtPostgresMicroseconds = "created_at_postgres_microseconds"
    }
}
private struct CrossStoreBatchProjectionOutcomeRow: Decodable {
    let ordinal: Int
    let userSyncSequence: Int64
    enum CodingKeys: String, CodingKey {
        case ordinal
        case userSyncSequence = "user_sync_sequence"
    }
}
private struct CrossStoreInboxInsertRow: Decodable { let sourceEventID: UUID; enum CodingKeys: String, CodingKey { case sourceEventID = "source_event_id" } }
private struct CrossStoreExistsRow: Decodable { let value: Int }
private struct CrossStoreCountRow: Decodable { let value: Int64 }
private struct CrossStoreSequenceRow: Decodable { let userSyncSequence: Int64; enum CodingKeys: String, CodingKey { case userSyncSequence = "user_sync_sequence" } }
private struct CrossStoreMirroredRecordRow: Decodable { let userSyncSequence: Int64; let payloadJSON: String; enum CodingKeys: String, CodingKey { case userSyncSequence = "user_sync_sequence", payloadJSON = "payload_json" } }
private struct CrossStoreSequenceOccupantRow: Decodable { let sourceEventID: UUID; let projectionKind: String; enum CodingKeys: String, CodingKey { case sourceEventID = "source_event_id", projectionKind = "projection_kind" } }
private func crossStoreUnsigned(_ value: Int64) throws -> UInt64 {
    guard value >= 0 else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return UInt64(value)
}
private func crossStoreBatchJSON<T: Encodable>(_ value: T) throws -> String {
    let data = try JSONEncoder().encode(value)
    guard let json = String(data: data, encoding: .utf8) else {
        throw V2RoomWriteStoreError.corruptPersistenceState
    }
    return json
}

/// 将跨存储投递耗时四舍五入为整数毫秒，用于批次完成后的统计。
///
/// - Parameter duration: 应由单调时钟测得的持续时间，避免系统时钟校准影响耗时。
/// - Returns: 正耗时按最近毫秒舍入的 `Int`；半毫秒向上取整，非正值或整数溢出返回零。
///
/// 保持此处的最近毫秒舍入规则，与一般遥测的向下截断规则不同。
/// 无效观测退回零值，使已经提交的业务批次不会因计时转换失败而报错。
func v2CrossStoreElapsedMilliseconds(_ duration: Duration) -> Int {
    guard duration > .zero else { return 0 }
    let components = duration.components
    let seconds = components.seconds.multipliedReportingOverflow(by: 1_000)
    let fractionalMilliseconds = (components.attoseconds + 500_000_000_000_000) / 1_000_000_000_000_000
    let result = seconds.partialValue.addingReportingOverflow(fractionalMilliseconds)
    guard !seconds.overflow, !result.overflow,
          let milliseconds = Int(exactly: result.partialValue) else { return 0 }
    return milliseconds
}
