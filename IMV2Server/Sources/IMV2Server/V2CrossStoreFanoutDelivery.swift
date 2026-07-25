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
                INSERT INTO \(unsafeRaw: table("user_sync_log"))
                    (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at)
                VALUES (
                    \(bind: targetUserID), \(bind: sequence.userSyncSequence), \(bind: sourceEventID), \(bind: input.projectionKind),
                    jsonb_build_object('source_event_id', \(bind: input.sourceEventID.rawValue),
                                       'projection_kind', \(bind: input.projectionKind)) || \(bind: input.eventPayloadJSON)::jsonb,
                    \(bind: now)
                )
                """).run()
            return try crossStoreUnsigned(sequence.userSyncSequence)
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

    public init(control: PostgresV2FanoutDeliveryStore, registry: any V2UserShardStorageResolving, migrations: PostgresV2UserShardMigrationStore) {
        self.control = control
        self.registry = registry
        self.migrations = migrations
    }

    public func claimPending(bucket: String?, now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2FanoutDeliveryLease] {
        try await control.claimPending(bucket: bucket, now: now, leaseDuration: leaseDuration, limit: limit)
    }

    public func commit(_ lease: V2FanoutDeliveryLease, now: Date) async throws -> V2FanoutDeliveryCommit {
        guard let input = try await control.projectionInput(for: lease) else { return .staleLease }
        let location = try registry.location(for: lease.observedRoute.bucket)
        let sequence = try await PostgresV2UserShardFanoutProjector(
            database: location.database, schema: location.schema
        ).project(input, now: now)
        if let migration = try await migrations.load(userID: lease.targetUserID),
           (migration.phase == .forwarding || migration.phase == .verified),
           migration.sourceBucket == lease.observedRoute.bucket {
            let shadow = try registry.location(for: migration.targetBucket)
            _ = try await PostgresV2UserShardFanoutProjector(
                database: shadow.database, schema: shadow.schema
            ).project(input, now: now)
        }
        return try await control.completeExternal(lease, userSyncSequence: sequence, now: now)
    }

    public func handoff(_ lease: V2FanoutDeliveryLease, to route: V2UserShardRoute) async throws {
        try await control.handoff(lease, to: route)
    }

    public func release(_ lease: V2FanoutDeliveryLease) async throws { try await control.release(lease) }

    public func scheduleRetry(_ lease: V2FanoutDeliveryLease, disposition: V2DurableRetryDisposition, now: Date) async throws {
        try await control.scheduleRetry(lease, disposition: disposition, now: now)
    }
}

private struct CrossStoreInboxInsertRow: Decodable { let sourceEventID: UUID; enum CodingKeys: String, CodingKey { case sourceEventID = "source_event_id" } }
private struct CrossStoreSequenceRow: Decodable { let userSyncSequence: Int64; enum CodingKeys: String, CodingKey { case userSyncSequence = "user_sync_sequence" } }
private struct CrossStoreMirroredRecordRow: Decodable { let userSyncSequence: Int64; let payloadJSON: String; enum CodingKeys: String, CodingKey { case userSyncSequence = "user_sync_sequence", payloadJSON = "payload_json" } }
private struct CrossStoreSequenceOccupantRow: Decodable { let sourceEventID: UUID; let projectionKind: String; enum CodingKeys: String, CodingKey { case sourceEventID = "source_event_id", projectionKind = "projection_kind" } }
private func crossStoreUnsigned(_ value: Int64) throws -> UInt64 {
    guard value >= 0 else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return UInt64(value)
}
