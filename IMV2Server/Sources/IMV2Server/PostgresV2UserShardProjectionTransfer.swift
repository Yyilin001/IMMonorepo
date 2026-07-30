import Crypto
import Fluent
import Foundation
import IMV2Core
import SQLKit

/// Physical data-plane adapter for the user-owned fan-out/sync projection
/// slice. Authentication remains owned by the Auth service; this transfers
/// only the receiver-inbox, user-sync and device-sync state named by the V2
/// service boundary. Bucket names are checked at the boundary and never stored
/// as physical addresses in delivery rows.
public struct PostgresV2UserShardProjectionTransfer: V2UserShardMigrationCopying, V2UserShardMigrationVerifying, V2UserShardMigrationRetentionCleaning {
    private let source: any Database
    private let target: any Database
    private let sourceBucket: String
    private let targetBucket: String
    private let sourceSchema: String
    private let targetSchema: String
    private let pageSize: Int

    public init(
        source: any Database,
        target: any Database,
        sourceBucket: String,
        targetBucket: String,
        sourceSchema: String = "im_v2",
        targetSchema: String = "im_v2",
        pageSize: Int = 1_000
    ) throws {
        let normalizedSource = sourceBucket.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTarget = targetBucket.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSource.isEmpty, !normalizedTarget.isEmpty, normalizedSource != normalizedTarget,
              Self.validSchema(sourceSchema), Self.validSchema(targetSchema), pageSize > 0
        else { throw V2UserShardProjectionTransferError.invalidConfiguration }
        self.source = source
        self.target = target
        self.sourceBucket = normalizedSource
        self.targetBucket = normalizedTarget
        self.sourceSchema = sourceSchema
        self.targetSchema = targetSchema
        self.pageSize = pageSize
    }

    public func copy(_ record: V2UserShardMigrationRecord) async throws {
        try validate(record)
        guard let sourceSQL = source as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let userID = try projectionUUID(record.userID)

        // Copy the bounded supporting records first. The append-only log is
        // paged separately so a large catch-up history never forms one SQL
        // statement or transaction on the target.
        let snapshot = try await loadSupportingSnapshot(sql: sourceSQL, userID: userID)
        try await target.transaction { database in
            guard let targetSQL = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            try await insertSupportingSnapshot(snapshot, userID: userID, sql: targetSQL)
        }

        var afterSequence: Int64 = 0
        while true {
            let page = try await sourceSQL.raw("""
                SELECT log.user_sync_sequence, log.source_event_id, log.projection_kind,
                       CASE WHEN log.payload_storage = 'inline' THEN log.payload ELSE shared.payload END::text AS payload_json,
                       log.payload_storage, log.created_at
                FROM \(unsafeRaw: sourceTable("user_sync_log")) AS log
                LEFT JOIN \(unsafeRaw: sourceTable("fanout_sync_payloads")) AS shared
                  ON shared.source_event_id = log.source_event_id
                 AND shared.projection_kind = log.projection_kind
                WHERE log.user_id = \(bind: userID) AND log.user_sync_sequence > \(bind: afterSequence)
                ORDER BY log.user_sync_sequence
                LIMIT \(bind: pageSize)
                """).all(decoding: ProjectionSyncLogRow.self)
            guard !page.isEmpty else { break }
            try await target.transaction { database in
                guard let targetSQL = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
                for row in page {
                    if row.payloadStorage == "fanout_shared" {
                        try await targetSQL.raw("""
                            INSERT INTO \(unsafeRaw: targetTable("fanout_sync_payloads"))
                                (source_event_id, projection_kind, payload, created_at)
                            VALUES (\(bind: row.sourceEventID), \(bind: row.projectionKind), \(bind: row.payloadJSON)::jsonb, \(bind: row.createdAt))
                            ON CONFLICT DO NOTHING
                            """).run()
                        guard let match = try await targetSQL.raw("""
                            SELECT 1 AS value FROM \(unsafeRaw: targetTable("fanout_sync_payloads"))
                            WHERE source_event_id = \(bind: row.sourceEventID)
                              AND projection_kind = \(bind: row.projectionKind)
                              AND payload = \(bind: row.payloadJSON)::jsonb
                            """).first(decoding: ProjectionPayloadMatchRow.self), match.value == 1 else {
                            throw V2RoomWriteStoreError.corruptPersistenceState
                        }
                    }
                    try await targetSQL.raw("""
                        INSERT INTO \(unsafeRaw: targetTable("user_sync_log"))
                            (user_id, user_sync_sequence, source_event_id, projection_kind, payload, payload_storage, created_at)
                        VALUES (\(bind: userID), \(bind: row.sequence), \(bind: row.sourceEventID), \(bind: row.projectionKind),
                                CASE WHEN \(bind: row.payloadStorage) = 'inline' THEN \(bind: row.payloadJSON)::jsonb ELSE NULL END,
                                \(bind: row.payloadStorage), \(bind: row.createdAt))
                        ON CONFLICT DO NOTHING
                        """).run()
                }
            }
            guard let last = page.last else { break }
            afterSequence = last.sequence
        }
    }

    public func fingerprints(for record: V2UserShardMigrationRecord) async throws -> (source: String, target: String) {
        try validate(record)
        guard let sourceSQL = source as? any SQLDatabase, let targetSQL = target as? any SQLDatabase else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let userID = try projectionUUID(record.userID)
        return (
            try await fingerprint(sql: sourceSQL, userID: userID),
            try await fingerprint(sql: targetSQL, userID: userID)
        )
    }

    public func cleanSource(for record: V2UserShardMigrationRecord) async throws {
        try validate(record)
        guard source is any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let userID = try projectionUUID(record.userID)
        try await source.transaction { database in
            guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            try await sql.raw("""
                DELETE FROM \(unsafeRaw: sourceTable("sync_snapshot_pages")) AS page
                USING \(unsafeRaw: sourceTable("sync_snapshots")) AS snapshot
                WHERE page.snapshot_id = snapshot.snapshot_id AND snapshot.user_id = \(bind: userID)
                """).run()
            for table in ["sync_snapshots", "sync_tokens", "sync_receipts", "device_sync_cursors", "user_sync_log", "user_sync_sequences"] {
                try await sql.raw("DELETE FROM \(unsafeRaw: sourceTable(table)) WHERE user_id = \(bind: userID)").run()
            }
            try await sql.raw("DELETE FROM \(unsafeRaw: sourceTable("consumer_inbox")) WHERE target_user_id = \(bind: userID)").run()
        }
    }

    private func loadSupportingSnapshot(sql: any SQLDatabase, userID: UUID) async throws -> ProjectionSupportingSnapshot {
        async let sequence = sql.raw("SELECT next_sequence FROM \(unsafeRaw: sourceTable("user_sync_sequences")) WHERE user_id = \(bind: userID)").first(decoding: ProjectionSequenceRow.self)
        async let inbox = sql.raw("""
            SELECT consumer_name, source_event_id, target_user_id, projection_kind, committed_at
            FROM \(unsafeRaw: sourceTable("consumer_inbox")) WHERE target_user_id = \(bind: userID)
            ORDER BY consumer_name, source_event_id, projection_kind
            """).all(decoding: ProjectionInboxRow.self)
        async let cursors = sql.raw("""
            SELECT user_id, device_id, state, reset_generation, acknowledged_sequence, pending_snapshot_id,
                   pending_base_sequence, pending_snapshot_expires_at, completed_snapshot_id, completed_snapshot_ack_receipt
            FROM \(unsafeRaw: sourceTable("device_sync_cursors")) WHERE user_id = \(bind: userID) ORDER BY device_id
            """).all(decoding: ProjectionCursorRow.self)
        async let snapshots = sql.raw("""
            SELECT snapshot_id, user_id, device_id, reset_generation, base_user_sync_sequence, manifest_digest,
                   schema_version, capability_profile, next_sync_token, sync_receipt, expires_at, state, created_at
            FROM \(unsafeRaw: sourceTable("sync_snapshots")) WHERE user_id = \(bind: userID) ORDER BY snapshot_id
            """).all(decoding: ProjectionSnapshotRow.self)
        async let pages = sql.raw("""
            SELECT page.snapshot_id, page.page_index, page.page_digest, page.payload
            FROM \(unsafeRaw: sourceTable("sync_snapshot_pages")) AS page
            JOIN \(unsafeRaw: sourceTable("sync_snapshots")) AS snapshot ON snapshot.snapshot_id = page.snapshot_id
            WHERE snapshot.user_id = \(bind: userID) ORDER BY page.snapshot_id, page.page_index
            """).all(decoding: ProjectionSnapshotPageRow.self)
        async let tokens = sql.raw("""
            SELECT token, user_id, device_id, reset_generation, watermark, expires_at, created_at
            FROM \(unsafeRaw: sourceTable("sync_tokens")) WHERE user_id = \(bind: userID) ORDER BY token
            """).all(decoding: ProjectionTokenRow.self)
        async let receipts = sql.raw("""
            SELECT receipt, user_id, device_id, reset_generation, first_sequence, last_sequence, expires_at, created_at
            FROM \(unsafeRaw: sourceTable("sync_receipts")) WHERE user_id = \(bind: userID) ORDER BY receipt
            """).all(decoding: ProjectionReceiptRow.self)
        return try await .init(sequence: sequence, inbox: inbox, cursors: cursors, snapshots: snapshots, pages: pages, tokens: tokens, receipts: receipts)
    }

    private func insertSupportingSnapshot(_ snapshot: ProjectionSupportingSnapshot, userID: UUID, sql: any SQLDatabase) async throws {
        if let sequence = snapshot.sequence {
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: targetTable("user_sync_sequences")) (user_id, next_sequence)
                VALUES (\(bind: userID), \(bind: sequence.nextSequence))
                ON CONFLICT (user_id) DO UPDATE SET next_sequence = GREATEST(\(unsafeRaw: targetTable("user_sync_sequences")).next_sequence, EXCLUDED.next_sequence)
                """).run()
        }
        for row in snapshot.inbox {
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: targetTable("consumer_inbox"))
                    (consumer_name, source_event_id, target_user_id, projection_kind, committed_at)
                VALUES (\(bind: row.consumerName), \(bind: row.sourceEventID), \(bind: row.targetUserID), \(bind: row.projectionKind), \(bind: row.committedAt))
                ON CONFLICT DO NOTHING
                """).run()
        }
        for row in snapshot.cursors {
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: targetTable("device_sync_cursors"))
                    (user_id, device_id, state, reset_generation, acknowledged_sequence, pending_snapshot_id,
                     pending_base_sequence, pending_snapshot_expires_at, completed_snapshot_id, completed_snapshot_ack_receipt)
                VALUES (\(bind: row.userID), \(bind: row.deviceID), \(bind: row.state), \(bind: row.resetGeneration), \(bind: row.acknowledgedSequence),
                        \(bind: row.pendingSnapshotID), \(bind: row.pendingBaseSequence), \(bind: row.pendingSnapshotExpiresAt),
                        \(bind: row.completedSnapshotID), \(bind: row.completedSnapshotAckReceipt))
                ON CONFLICT DO NOTHING
                """).run()
        }
        for row in snapshot.snapshots {
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: targetTable("sync_snapshots"))
                    (snapshot_id, user_id, device_id, reset_generation, base_user_sync_sequence, manifest_digest,
                     schema_version, capability_profile, next_sync_token, sync_receipt, expires_at, state, created_at)
                VALUES (\(bind: row.snapshotID), \(bind: row.userID), \(bind: row.deviceID), \(bind: row.resetGeneration), \(bind: row.baseSequence),
                        \(bind: row.manifestDigest), \(bind: row.schemaVersion), \(bind: row.capabilityProfile), \(bind: row.nextSyncToken),
                        \(bind: row.receipt), \(bind: row.expiresAt), \(bind: row.state), \(bind: row.createdAt))
                ON CONFLICT DO NOTHING
                """).run()
        }
        for row in snapshot.pages {
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: targetTable("sync_snapshot_pages")) (snapshot_id, page_index, page_digest, payload)
                VALUES (\(bind: row.snapshotID), \(bind: row.index), \(bind: row.digest), \(bind: row.payload))
                ON CONFLICT DO NOTHING
                """).run()
        }
        for row in snapshot.tokens {
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: targetTable("sync_tokens"))
                    (token, user_id, device_id, reset_generation, watermark, expires_at, created_at)
                VALUES (\(bind: row.token), \(bind: row.userID), \(bind: row.deviceID), \(bind: row.resetGeneration), \(bind: row.watermark), \(bind: row.expiresAt), \(bind: row.createdAt))
                ON CONFLICT DO NOTHING
                """).run()
        }
        for row in snapshot.receipts {
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: targetTable("sync_receipts"))
                    (receipt, user_id, device_id, reset_generation, first_sequence, last_sequence, expires_at, created_at)
                VALUES (\(bind: row.receipt), \(bind: row.userID), \(bind: row.deviceID), \(bind: row.resetGeneration),
                        \(bind: row.firstSequence), \(bind: row.lastSequence), \(bind: row.expiresAt), \(bind: row.createdAt))
                ON CONFLICT DO NOTHING
                """).run()
        }
    }

    private func fingerprint(sql: any SQLDatabase, userID: UUID) async throws -> String {
        let snapshot = try await loadSupportingSnapshot(sql: sql, userID: userID)
        var lines = snapshot.canonicalLines()
        var afterSequence: Int64 = 0
        while true {
            let page = try await sql.raw("""
                SELECT log.user_sync_sequence, log.source_event_id, log.projection_kind,
                       CASE WHEN log.payload_storage = 'inline' THEN log.payload ELSE shared.payload END::text AS payload_json,
                       log.payload_storage, log.created_at
                FROM \(unsafeRaw: sourceTable("user_sync_log")) AS log
                LEFT JOIN \(unsafeRaw: sourceTable("fanout_sync_payloads")) AS shared
                  ON shared.source_event_id = log.source_event_id
                 AND shared.projection_kind = log.projection_kind
                WHERE log.user_id = \(bind: userID) AND log.user_sync_sequence > \(bind: afterSequence)
                ORDER BY log.user_sync_sequence LIMIT \(bind: pageSize)
                """).all(decoding: ProjectionSyncLogRow.self)
            guard !page.isEmpty else { break }
            lines.append(contentsOf: page.map(ProjectionSyncLogRow.canonicalLine))
            afterSequence = page[page.count - 1].sequence
        }
        let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private func validate(_ record: V2UserShardMigrationRecord) throws {
        guard record.sourceBucket == sourceBucket, record.targetBucket == targetBucket else {
            throw V2UserShardProjectionTransferError.routeMismatch
        }
    }

    private func sourceTable(_ name: String) -> String { "\(sourceSchema).\(name)" }
    private func targetTable(_ name: String) -> String { "\(targetSchema).\(name)" }
    private static func validSchema(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
    }
}

public enum V2UserShardProjectionTransferError: Error, Equatable, Sendable {
    case invalidConfiguration
    case routeMismatch
}

private struct ProjectionSupportingSnapshot: Sendable {
    let sequence: ProjectionSequenceRow?
    let inbox: [ProjectionInboxRow]
    let cursors: [ProjectionCursorRow]
    let snapshots: [ProjectionSnapshotRow]
    let pages: [ProjectionSnapshotPageRow]
    let tokens: [ProjectionTokenRow]
    let receipts: [ProjectionReceiptRow]

    func canonicalLines() -> [String] {
        // Keep the construction deliberately incremental.  The chained array
        // concatenation is concise, but exceeds the Linux Swift compiler's
        // type-checking budget for this generic-heavy module.
        var lines = sequence.map { ["sequence|\($0.nextSequence)"] } ?? []
        lines.append(contentsOf: inbox.map(ProjectionInboxRow.canonicalLine))
        lines.append(contentsOf: cursors.map(ProjectionCursorRow.canonicalLine))
        lines.append(contentsOf: snapshots.map(ProjectionSnapshotRow.canonicalLine))
        lines.append(contentsOf: pages.map(ProjectionSnapshotPageRow.canonicalLine))
        lines.append(contentsOf: tokens.map(ProjectionTokenRow.canonicalLine))
        lines.append(contentsOf: receipts.map(ProjectionReceiptRow.canonicalLine))
        return lines
    }
}

private struct ProjectionSequenceRow: Decodable, Sendable { let nextSequence: Int64; enum CodingKeys: String, CodingKey { case nextSequence = "next_sequence" } }
private struct ProjectionInboxRow: Decodable, Sendable {
    let consumerName: String; let sourceEventID: UUID; let targetUserID: UUID; let projectionKind: String; let committedAt: Date
    enum CodingKeys: String, CodingKey { case consumerName = "consumer_name", sourceEventID = "source_event_id", targetUserID = "target_user_id", projectionKind = "projection_kind", committedAt = "committed_at" }
    // This is delivery bookkeeping, not receiver-visible projection state. A
    // retry may create the shadow inbox row after source committed, so its
    // wall-clock time cannot participate in a migration equivalence proof.
    static func canonicalLine(_ row: Self) -> String { "inbox|\(row.consumerName)|\(row.sourceEventID)|\(row.targetUserID)|\(row.projectionKind)" }
}
private struct ProjectionSyncLogRow: Decodable, Sendable {
    let sequence: Int64; let sourceEventID: UUID; let projectionKind: String; let payloadJSON: String; let payloadStorage: String; let createdAt: Date
    enum CodingKeys: String, CodingKey { case sequence = "user_sync_sequence", sourceEventID = "source_event_id", projectionKind = "projection_kind", payloadJSON = "payload_json", payloadStorage = "payload_storage", createdAt = "created_at" }
    // The event payload and per-user sequence define what a receiver observes;
    // `created_at` is local commit timing and can differ across a recovered
    // source-to-target shadow write.
    static func canonicalLine(_ row: Self) -> String { "log|\(row.sequence)|\(row.sourceEventID)|\(row.projectionKind)|\(row.payloadJSON)" }
}
private struct ProjectionPayloadMatchRow: Decodable, Sendable { let value: Int }
private struct ProjectionCursorRow: Decodable, Sendable {
    let userID: UUID; let deviceID: UUID; let state: String; let resetGeneration: Int64; let acknowledgedSequence: Int64; let pendingSnapshotID: UUID?; let pendingBaseSequence: Int64?; let pendingSnapshotExpiresAt: Date?; let completedSnapshotID: UUID?; let completedSnapshotAckReceipt: String?
    enum CodingKeys: String, CodingKey { case userID = "user_id", deviceID = "device_id", state, resetGeneration = "reset_generation", acknowledgedSequence = "acknowledged_sequence", pendingSnapshotID = "pending_snapshot_id", pendingBaseSequence = "pending_base_sequence", pendingSnapshotExpiresAt = "pending_snapshot_expires_at", completedSnapshotID = "completed_snapshot_id", completedSnapshotAckReceipt = "completed_snapshot_ack_receipt" }
    static func canonicalLine(_ row: Self) -> String { "cursor|\(row.userID)|\(row.deviceID)|\(row.state)|\(row.resetGeneration)|\(row.acknowledgedSequence)|\(projectionOptional(row.pendingSnapshotID))|\(projectionOptional(row.pendingBaseSequence))|\(projectionOptionalDate(row.pendingSnapshotExpiresAt))|\(projectionOptional(row.completedSnapshotID))|\(projectionOptional(row.completedSnapshotAckReceipt))" }
}
private struct ProjectionSnapshotRow: Decodable, Sendable {
    let snapshotID: UUID; let userID: UUID; let deviceID: UUID; let resetGeneration: Int64; let baseSequence: Int64; let manifestDigest: String; let schemaVersion: Int32; let capabilityProfile: String; let nextSyncToken: String; let receipt: String; let expiresAt: Date; let state: String; let createdAt: Date
    enum CodingKeys: String, CodingKey { case snapshotID = "snapshot_id", userID = "user_id", deviceID = "device_id", resetGeneration = "reset_generation", baseSequence = "base_user_sync_sequence", manifestDigest = "manifest_digest", schemaVersion = "schema_version", capabilityProfile = "capability_profile", nextSyncToken = "next_sync_token", receipt = "sync_receipt", expiresAt = "expires_at", state, createdAt = "created_at" }
    static func canonicalLine(_ row: Self) -> String { "snapshot|\(row.snapshotID)|\(row.userID)|\(row.deviceID)|\(row.resetGeneration)|\(row.baseSequence)|\(row.manifestDigest)|\(row.schemaVersion)|\(row.capabilityProfile)|\(row.nextSyncToken)|\(row.receipt)|\(projectionDate(row.expiresAt))|\(row.state)|\(projectionDate(row.createdAt))" }
}
private struct ProjectionSnapshotPageRow: Decodable, Sendable {
    let snapshotID: UUID; let index: Int; let digest: String; let payload: Data
    enum CodingKeys: String, CodingKey { case snapshotID = "snapshot_id", index = "page_index", digest = "page_digest", payload }
    static func canonicalLine(_ row: Self) -> String { "page|\(row.snapshotID)|\(row.index)|\(row.digest)|\(row.payload.base64EncodedString())" }
}
private struct ProjectionTokenRow: Decodable, Sendable {
    let token: String; let userID: UUID; let deviceID: UUID; let resetGeneration: Int64; let watermark: Int64; let expiresAt: Date; let createdAt: Date
    enum CodingKeys: String, CodingKey { case token, userID = "user_id", deviceID = "device_id", resetGeneration = "reset_generation", watermark, expiresAt = "expires_at", createdAt = "created_at" }
    static func canonicalLine(_ row: Self) -> String { "token|\(row.token)|\(row.userID)|\(row.deviceID)|\(row.resetGeneration)|\(row.watermark)|\(projectionDate(row.expiresAt))|\(projectionDate(row.createdAt))" }
}
private struct ProjectionReceiptRow: Decodable, Sendable {
    let receipt: String; let userID: UUID; let deviceID: UUID; let resetGeneration: Int64; let firstSequence: Int64; let lastSequence: Int64; let expiresAt: Date; let createdAt: Date
    enum CodingKeys: String, CodingKey { case receipt, userID = "user_id", deviceID = "device_id", resetGeneration = "reset_generation", firstSequence = "first_sequence", lastSequence = "last_sequence", expiresAt = "expires_at", createdAt = "created_at" }
    static func canonicalLine(_ row: Self) -> String { "receipt|\(row.receipt)|\(row.userID)|\(row.deviceID)|\(row.resetGeneration)|\(row.firstSequence)|\(row.lastSequence)|\(projectionDate(row.expiresAt))|\(projectionDate(row.createdAt))" }
}

private func projectionUUID(_ userID: UserID) throws -> UUID {
    guard let value = UUID(uuidString: userID.rawValue) else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return value
}
private func projectionDate(_ value: Date) -> String { String(value.timeIntervalSinceReferenceDate) }
private func projectionOptional<T>(_ value: T?) -> String { value.map { String(describing: $0) } ?? "<nil>" }
private func projectionOptionalDate(_ value: Date?) -> String { value.map(projectionDate) ?? "<nil>" }
