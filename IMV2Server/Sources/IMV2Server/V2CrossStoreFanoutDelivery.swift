import Fluent
import Foundation
import IMV2Core
import SQLKit

/// Immutable source payload prepared by the control store for a single
/// fan-out effect. It deliberately contains logical IDs only, never a bucket
/// address or a connection string.
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

/// Immutable cross-store transport for one canonical message state. It has no
/// bucket or connection information and uses the globally stable state ID, so
/// a target-shard retry can verify or reuse it without remapping identifiers.
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
    }

    init(_ value: V2StoredMessageProjectionState) {
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

/// Privacy-safe timing for one bounded remote target projection and its
/// control-store acknowledgement. It intentionally contains only aggregate
/// counts and elapsed durations: room, event, user, bucket and payload values
/// never reach an observer.
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

/// Optional diagnostic seam for remote fan-out. Production composition can
/// leave it unset; a recorder must not participate in delivery correctness.
public protocol V2CrossStoreFanoutDeliveryTimingRecording: Sendable {
    func record(_ timing: V2CrossStoreFanoutBatchTiming) async
}

/// An already-committed user-sync record mirrored during a user-shard move.
/// Unlike fan-out input, this preserves the source-assigned sequence and
/// payload: direct/social authority commits in the control store first and
/// must never manufacture a second user-visible event on the target shard.
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

/// Target-store half of a cross-store fan-out delivery. The inbox insert and
/// sequence/log write share one target transaction. If a process dies before
/// the control store is completed, a retry returns the already committed
/// sequence instead of producing a second user-visible record.
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
                RETURNING next_sequence AS user_sync_sequence
                """).first(decoding: CrossStoreSequenceRow.self)
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            if let messageState = input.messageState {
                guard input.projectionKind == "message" else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                try await PostgresV2MessageProjectionStateRepository(schema: schema)
                    .persist(messageState.stored, sql: sql)
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
                LEFT JOIN \(unsafeRaw: table("message_projection_states")) AS state
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

    /// Projects one bounded, same-physical-shard batch in one target-store
    /// transaction.  Control-store completion intentionally remains outside
    /// this transaction: PostgreSQL cannot atomically commit across the two
    /// databases. If the process stops after this target commit, a retry
    /// reads the inbox-backed sync sequence below and completes only the
    /// still-fenced control delivery. Repeated immutable event payloads are
    /// sent as a separate, deduplicated table: a normal room-event batch has
    /// one payload for many target rows, so repeating it per target would
    /// needlessly consume wire, JSON parsing and PostgreSQL memory.
    public func projectBatch(_ inputs: [V2FanoutProjectionInput], now: Date) async throws -> [UInt64] {
        guard !inputs.isEmpty else { return [] }
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
                       to_timestamp((created_at_microseconds / 1000000)::double precision)
                         + (created_at_microseconds % 1000000)
                           * INTERVAL '1 microsecond'
                FROM jsonb_to_recordset(\(bind: messageStateJSON)::jsonb) AS value(
                    state_id uuid, message_id uuid, room_id uuid,
                    message_revision bigint, variant_key smallint,
                    origin_event_id uuid, state_event_id uuid,
                    is_withdrawn boolean, payload_schema_version smallint,
                    payload_json text, created_at_microseconds bigint
                )
                ON CONFLICT DO NOTHING
                """).run()
            guard let stateVerification = try await sql.raw("""
                SELECT COUNT(*)::bigint AS value
                FROM jsonb_to_recordset(\(bind: messageStateJSON)::jsonb) AS value(
                    state_id uuid, message_id uuid, room_id uuid,
                    message_revision bigint, variant_key smallint,
                    origin_event_id uuid, state_event_id uuid,
                    is_withdrawn boolean, payload_schema_version smallint,
                    payload_json text, created_at_microseconds bigint
                )
                JOIN \(unsafeRaw: table("message_projection_states")) AS stored
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
                 AND stored.created_at =
                     to_timestamp(
                         (value.created_at_microseconds / 1000000)::double precision
                     )
                     + (value.created_at_microseconds % 1000000)
                       * INTERVAL '1 microsecond'
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
                LEFT JOIN \(unsafeRaw: table("message_projection_states")) AS state
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
                    LEFT JOIN \(unsafeRaw: table("message_projection_states")) AS state
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

    /// Mirrors a source-owned sync record without changing its sequence. It
    /// first uses the semantic `(user, source event, kind)` identity; a
    /// sequence collision with a different record is persistence corruption,
    /// not a conflict to overwrite during migration.
    public func mirror(_ record: V2UserSyncProjectionMirror) async throws -> UInt64 {
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
                        \(bind: record.payloadJSON)::jsonb, \(bind: record.createdAt))
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

    /// Appends a control-plane-owned projection to whichever user shard is
    /// currently authoritative. Its source event/kind identity makes retries
    /// idempotent, while the sequence is allocated by that shard. This is
    /// required after cutover: the control database's historical counter is
    /// no longer the target user's live sequence counter.
    public func projectAllocated(
        userID: UserID,
        sourceEventID: EventID,
        projectionKind: String,
        payloadJSON: String,
        createdAt: Date
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
            guard let sequence = try await sql.raw("""
                INSERT INTO \(unsafeRaw: table("user_sync_sequences")) (user_id, next_sequence)
                VALUES (\(bind: userUUID), 1)
                ON CONFLICT (user_id)
                DO UPDATE SET next_sequence = \(unsafeRaw: table("user_sync_sequences")).next_sequence + 1
                RETURNING next_sequence AS user_sync_sequence
                """).first(decoding: CrossStoreSequenceRow.self)
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: table("user_sync_log"))
                    (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at)
                VALUES (\(bind: userUUID), \(bind: sequence.userSyncSequence), \(bind: eventUUID), \(bind: projectionKind),
                        \(bind: payloadJSON)::jsonb, \(bind: createdAt))
                """).run()
            return try crossStoreUnsigned(sequence.userSyncSequence)
        }
    }

    private func table(_ name: String) -> String { "\(schema).\(name)" }
}

/// Keeps fan-out control records in their authoritative database while
/// materializing the per-user projection in the physical store chosen by the
/// durable logical route. All lease/retry/handoff operations remain control
/// store operations; only the user projection crosses stores.
public struct V2CrossStoreFanoutDeliveryStore: V2PartitionedFanoutDeliveryStore, Sendable {
    private let control: PostgresV2FanoutDeliveryStore
    private let registry: any V2UserShardStorageResolving
    private let migrations: PostgresV2UserShardMigrationStore
    /// Set only by the composition root after it has established that this
    /// bucket uses the control database's `im_v2` schema. It is intentionally
    /// topology data rather than a best-effort comparison of database objects.
    private let coLocatedControlBucket: String?
    /// Payloads above this size are returned once per source event in a
    /// lease-claim result. The remaining claimed leases are completed from a
    /// process-local copy before any target transaction starts. This keeps a
    /// large immutable room event from becoming a member-count-scaled control
    /// response, without adding a second control-store read.
    private let maximumInlineClaimPayloadBytes: Int
    private let payloadWriteMode: V2FanoutPayloadWriteMode
    private let timingRecorder: (any V2CrossStoreFanoutDeliveryTimingRecording)?

    /// A remote user shard's target transaction and control completion are
    /// two ordered database boundaries. Multiple claim workers for the same
    /// remote bucket fragment `SKIP LOCKED` claims and contend on completion
    /// units; the isolated 5k profile regressed under four such workers.
    /// Co-located buckets retain parallel projection, but cap one physical
    /// PostgreSQL shard at the measured eight claim passes: sixteen adds lock
    /// and claim work without reducing end-to-end latency in the 80k profile.
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

    /// Uses the control store's native atomic batch only when deployment
    /// topology proves every projection is in that same `im_v2` schema and no
    /// forwarding/verified move needs a shadow write. For an external bucket,
    /// the target inbox/sequence/log effects are instead batched in that one
    /// physical user database; each successful target sequence is then
    /// completed through its independent control-store lease fence. A
    /// forwarding user deliberately keeps the established per-target protocol
    /// because it also needs a second, migration-target projection.
    public func commitBatch(_ leases: [V2FanoutDeliveryLease], now: Date) async throws -> [V2FanoutDeliveryCommit] {
        guard !leases.isEmpty else { return [] }
        if try await canCommitAtomicallyInControlStore(leases) {
            return try await control.commitBatchFencedToCurrentRoutes(leases, now: now)
        }
        var results = Array<V2FanoutDeliveryCommit?>(repeating: nil, count: leases.count)
        let grouped = Dictionary(grouping: leases.enumerated(), by: { $0.element.observedRoute.bucket })
        for bucket in grouped.keys.sorted() {
            guard let items = grouped[bucket] else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let batchStartedAt = Date()
            let location = try registry.location(for: bucket)
            let migrationReadStartedAt = Date()
            let migrationRecords = try await migrations.load(userIDs: Array(Set(items.map(\.element.targetUserID))).sorted())
            let migrationReadMilliseconds = v2CrossStoreElapsedMilliseconds(since: migrationReadStartedAt)
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
                let targetProjectionStartedAt = Date()
                let sequences = try await projector.projectBatch(batch.map(\.input), now: now)
                let targetProjectionMilliseconds = v2CrossStoreElapsedMilliseconds(since: targetProjectionStartedAt)
                guard sequences.count == batch.count else { throw V2RoomWriteStoreError.corruptPersistenceState }
                let acknowledgements = zip(batch, sequences).map {
                    V2ExternalFanoutDeliveryAcknowledgement(lease: $0.lease, userSyncSequence: $1)
                }
                let controlCompletionStartedAt = Date()
                let completions = try await control.completeExternalBatch(acknowledgements, now: now)
                let controlCompletionMilliseconds = v2CrossStoreElapsedMilliseconds(since: controlCompletionStartedAt)
                guard completions.count == batch.count else { throw V2RoomWriteStoreError.corruptPersistenceState }
                for (item, completion) in zip(batch, completions) {
                    results[item.index] = completion
                }
                await timingRecorder?.record(.init(
                    targetCount: batch.count,
                    migrationReadMilliseconds: migrationReadMilliseconds,
                    targetProjectionMilliseconds: targetProjectionMilliseconds,
                    controlCompletionMilliseconds: controlCompletionMilliseconds,
                    totalMilliseconds: v2CrossStoreElapsedMilliseconds(since: batchStartedAt)
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
    let createdAtMicroseconds: Int64

    init(_ value: V2FanoutMessageProjectionState) throws {
        let microseconds = (value.createdAt.timeIntervalSince1970 * 1_000_000).rounded(.down)
        guard microseconds.isFinite,
              microseconds >= Double(Int64.min),
              microseconds <= Double(Int64.max)
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
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
        createdAtMicroseconds = Int64(microseconds)
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
        case createdAtMicroseconds = "created_at_microseconds"
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

private func v2CrossStoreElapsedMilliseconds(since startedAt: Date, now: Date = Date()) -> Int {
    max(0, Int((now.timeIntervalSince(startedAt) * 1_000).rounded()))
}
