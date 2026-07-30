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

    public init(sourceEventID: EventID, targetUserID: UserID, projectionKind: String, eventPayloadJSON: String) {
        self.sourceEventID = sourceEventID
        self.targetUserID = targetUserID
        self.projectionKind = projectionKind
        self.eventPayloadJSON = eventPayloadJSON
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

    public init(database: any Database, schema: String) throws {
        guard schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
            throw V2UserShardStorageRegistryError.invalidLocation
        }
        self.database = database
        self.schema = schema
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
                    FROM \(unsafeRaw: table("user_sync_log"))
                    WHERE user_id = \(bind: targetUserID) AND source_event_id = \(bind: sourceEventID)
                      AND projection_kind = \(bind: input.projectionKind)
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
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: table("fanout_sync_payloads"))
                    (source_event_id, projection_kind, payload, created_at)
                VALUES (\(bind: sourceEventID), \(bind: input.projectionKind), \(bind: input.eventPayloadJSON)::jsonb, \(bind: now))
                ON CONFLICT DO NOTHING
                """).run()
            guard let shared = try await sql.raw("""
                SELECT 1 AS value
                FROM \(unsafeRaw: table("fanout_sync_payloads"))
                WHERE source_event_id = \(bind: sourceEventID)
                  AND projection_kind = \(bind: input.projectionKind)
                  AND payload = \(bind: input.eventPayloadJSON)::jsonb
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
            return CrossStoreBatchProjectionInput(
                ordinal: index, sourceEventID: sourceEventID, targetUserID: targetUserID,
                projectionKind: input.projectionKind, payloadIndex: payloadIndex
            )
        }
        let identities = encoded.map {
            "\($0.sourceEventID.uuidString)|\($0.targetUserID.uuidString)|\($0.projectionKind)"
        }
        guard Set(identities).count == encoded.count else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let inputJSON = try crossStoreBatchJSON(encoded)
        let payloadJSON = try crossStoreBatchJSON(uniquePayloads)
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
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
                    SELECT value.source_event_id, value.projection_kind, payload.event_payload
                    FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb) AS value(
                        ordinal integer, source_event_id uuid, target_user_id uuid,
                        projection_kind text, payload_index integer
                    )
                    JOIN payloads AS payload ON payload.payload_index = value.payload_index
                ), payload_keys AS MATERIALIZED (
                    SELECT DISTINCT source_event_id, projection_kind, event_payload FROM input
                )
                INSERT INTO \(unsafeRaw: table("fanout_sync_payloads"))
                    (source_event_id, projection_kind, payload, created_at)
                SELECT source_event_id, projection_kind, event_payload, \(bind: now)
                FROM payload_keys
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
                           value.projection_kind, payload.event_payload
                    FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb) AS value(
                        ordinal integer, source_event_id uuid, target_user_id uuid,
                        projection_kind text, payload_index integer
                    )
                    JOIN payloads AS payload ON payload.payload_index = value.payload_index
                ), payload_keys AS MATERIALIZED (
                    SELECT DISTINCT source_event_id, projection_kind, event_payload
                    FROM input
                ), verified_payloads AS MATERIALIZED (
                    SELECT payload_keys.source_event_id, payload_keys.projection_kind
                    FROM payload_keys
                    JOIN \(unsafeRaw: table("fanout_sync_payloads")) AS shared
                      ON shared.source_event_id = payload_keys.source_event_id
                     AND shared.projection_kind = payload_keys.projection_kind
                     AND shared.payload = payload_keys.event_payload
                ), inserted_inbox AS (
                    INSERT INTO \(unsafeRaw: table("consumer_inbox"))
                        (consumer_name, source_event_id, target_user_id, projection_kind, committed_at)
                    SELECT \(bind: consumerName), source_event_id, target_user_id, projection_kind, \(bind: now)
                    FROM input
                    ON CONFLICT DO NOTHING
                    RETURNING source_event_id, target_user_id, projection_kind
                ), per_user AS (
                    SELECT target_user_id AS user_id, COUNT(*)::bigint AS sequence_count
                    FROM inserted_inbox
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
                    JOIN inserted_inbox
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
                ), inserted_outcomes AS (
                    SELECT numbered.ordinal, inserted_log.user_sync_sequence
                    FROM numbered
                    JOIN inserted_log
                      ON inserted_log.user_id = numbered.target_user_id
                     AND inserted_log.user_sync_sequence = numbered.user_sync_sequence
                     AND inserted_log.source_event_id = numbered.source_event_id
                     AND inserted_log.projection_kind = numbered.projection_kind
                ), conflict_input AS (
                    SELECT input.ordinal, input.source_event_id, input.target_user_id, input.projection_kind
                    FROM input
                    LEFT JOIN inserted_inbox
                      USING (source_event_id, target_user_id, projection_kind)
                    WHERE inserted_inbox.source_event_id IS NULL
                ), conflict_outcomes AS (
                    SELECT conflict.ordinal, log.user_sync_sequence
                    FROM conflict_input AS conflict
                    JOIN \(unsafeRaw: table("user_sync_log")) AS log
                      ON log.user_id = conflict.target_user_id
                     AND log.source_event_id = conflict.source_event_id
                     AND log.projection_kind = conflict.projection_kind
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
                FROM \(unsafeRaw: table("user_sync_log"))
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
            guard let mirrored = try await sql.raw("""
                SELECT user_sync_sequence, payload::text AS payload_json
                FROM \(unsafeRaw: table("user_sync_log"))
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
                FROM \(unsafeRaw: table("user_sync_log"))
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
public struct V2CrossStoreFanoutDeliveryStore: V2FanoutDeliveryStore, Sendable {
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
        timingRecorder: (any V2CrossStoreFanoutDeliveryTimingRecording)? = nil
    ) {
        precondition(maximumInlineClaimPayloadBytes > 0)
        self.control = control
        self.registry = registry
        self.migrations = migrations
        self.coLocatedControlBucket = coLocatedControlBucket
        self.maximumInlineClaimPayloadBytes = maximumInlineClaimPayloadBytes
        self.timingRecorder = timingRecorder
    }

    public func claimPending(bucket: String?, lane: V2FanoutDeliveryClaimLane, now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2FanoutDeliveryLease] {
        // A co-located target commits through `control.commitBatch`, which
        // reads the immutable payload inside that same control-database
        // transaction. Returning it from the claim would add a room-event
        // join, JSON serialization and process-memory copy that this path
        // never consumes. Remote targets retain the enriched claim because
        // their independent target transaction needs the source payload.
        if bucket == coLocatedControlBucket {
            return try await control.claimPending(
                bucket: bucket, lane: lane, now: now,
                leaseDuration: leaseDuration, limit: limit
            )
        }
        let leases = try await control.claimPendingIncludingProjectionPayload(
            bucket: bucket, lane: lane, now: now, leaseDuration: leaseDuration, limit: limit,
            maximumInlinePayloadBytes: maximumInlineClaimPayloadBytes
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
        if let payload = lease.eventPayloadJSON {
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
            database: location.database, schema: location.schema
        ).project(input, now: now)
        let migration = try await migrations.load(userID: lease.targetUserID)
        if requiresForwardingShadow(for: lease, migration: migration) {
            guard let migration else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let shadow = try registry.location(for: migration.targetBucket)
            _ = try await PostgresV2UserShardFanoutProjector(
                database: shadow.database, schema: shadow.schema
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
            return try await control.commitBatch(leases, now: now)
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
            for candidate in candidates where candidate.lease.eventPayloadJSON != nil {
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
            let payloadReadCandidates = candidates.filter { $0.lease.eventPayloadJSON == nil }
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
                    database: location.database, schema: location.schema
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

    enum CodingKeys: String, CodingKey {
        case ordinal
        case sourceEventID = "source_event_id"
        case targetUserID = "target_user_id"
        case projectionKind = "projection_kind"
        case payloadIndex = "payload_index"
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
