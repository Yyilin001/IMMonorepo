import Fluent
import Foundation
import IMV2Core
import SQLKit

/// PostgreSQL cursor and reset fence. Pull/ack never trust a client-supplied
/// sequence beyond the device cursor's generation and durable log watermark.
public struct PostgresV2SyncStore: V2SyncStore {
    private let database: any Database
    private let schema: String
    private let makeUUID: @Sendable () -> UUID
    private let capabilityLifetime: TimeInterval

    public init(database: any Database, schema: String = "im_v2", makeUUID: @escaping @Sendable () -> UUID = { UUID() }, capabilityLifetime: TimeInterval = 86_400) {
        precondition(capabilityLifetime > 0)
        precondition(schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil)
        self.database = database
        self.schema = schema
        self.makeUUID = makeUUID
        self.capabilityLifetime = capabilityLifetime
    }

    public func pull(userID: UserID, deviceID: DeviceID, syncToken: V2SyncToken?, maxRecords: Int, now: Date) async throws -> V2SyncPullResult {
        guard maxRecords > 0 else { throw V2SyncStoreError.invalidRecordLimit }
        let userUUID = try uuid(userID)
        let deviceUUID = try uuid(deviceID)
        try await ensureCursor(userID: userUUID, deviceID: deviceUUID)
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard let cursor = try await fetchCursor(sql: sql, userID: userUUID, deviceID: deviceUUID, lock: true) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            if cursor.state == "reset_pending" {
                guard let snapshotID = cursor.pendingSnapshotID,
                      let base = cursor.pendingBaseSequence,
                      let snapshot = try await sql.raw("""
                    SELECT manifest_digest, expires_at FROM \(unsafeRaw: table("sync_snapshots"))
                    WHERE snapshot_id = \(bind: snapshotID) AND state = 'staged'
                    """).first(decoding: SnapshotMetadataRow.self)
                else { throw V2RoomWriteStoreError.corruptPersistenceState }
                return .resetRequired(
                    snapshotID: try SnapshotID(snapshotID.uuidString),
                    generation: try unsigned(cursor.resetGeneration),
                    baseSequence: try unsigned(base),
                    manifestDigest: snapshot.manifestDigest,
                    expiresAt: snapshot.expiresAt
                )
            }
            guard cursor.state == "ready" else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let generation = try unsigned(cursor.resetGeneration)
            let startSequence: Int64
            if let syncToken {
                guard let issued = try await sql.raw("""
                    SELECT watermark FROM \(unsafeRaw: table("sync_tokens"))
                    WHERE token = \(bind: syncToken.rawValue) AND user_id = \(bind: userUUID) AND device_id = \(bind: deviceUUID)
                      AND reset_generation = \(bind: cursor.resetGeneration) AND expires_at > \(bind: now)
                    """).first(decoding: SyncTokenRow.self)
                else { throw V2SyncStoreError.invalidOrExpiredSyncToken }
                startSequence = issued.watermark
            } else {
                startSequence = cursor.acknowledgedSequence
            }
            let rows = try await sql.raw("""
                SELECT user_sync_sequence, source_event_id, projection_kind, payload::text AS payload_json
                FROM \(unsafeRaw: table("user_sync_log"))
                WHERE user_id = \(bind: userUUID) AND user_sync_sequence > \(bind: startSequence)
                ORDER BY user_sync_sequence LIMIT \(bind: maxRecords + 1)
                """).all(decoding: SyncLogRow.self)
            let hasMore = rows.count > maxRecords
            let records = try rows.prefix(maxRecords).map {
                V2SyncRecord(sequence: try unsigned($0.sequence), sourceEventID: try EventID($0.sourceEventID.uuidString), projectionKind: $0.projectionKind, payloadJSON: $0.payloadJSON)
            }
            let lastSequence = try records.last.map { try signed($0.sequence) } ?? startSequence
            let firstSequence = try records.first.map { try signed($0.sequence) } ?? startSequence
            let expiresAt = now.addingTimeInterval(capabilityLifetime)
            let nextToken = try V2SyncToken(makeUUID().uuidString)
            let receipt = try V2SyncReceipt(makeUUID().uuidString)
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: table("sync_tokens")) (token, user_id, device_id, reset_generation, watermark, expires_at, created_at)
                VALUES (\(bind: nextToken.rawValue), \(bind: userUUID), \(bind: deviceUUID), \(bind: cursor.resetGeneration), \(bind: lastSequence), \(bind: expiresAt), \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: table("sync_receipts")) (receipt, user_id, device_id, reset_generation, first_sequence, last_sequence, expires_at, created_at)
                VALUES (\(bind: receipt.rawValue), \(bind: userUUID), \(bind: deviceUUID), \(bind: cursor.resetGeneration), \(bind: firstSequence), \(bind: lastSequence), \(bind: expiresAt), \(bind: now))
                """).run()
            return .ready(generation: generation, records: records, nextSyncToken: nextToken, receipt: receipt, hasMore: hasMore)
        }
    }

    public func acknowledge(userID: UserID, deviceID: DeviceID, generation: UInt64, highestContiguousSequence: UInt64, receipt: V2SyncReceipt, now: Date) async throws {
        let userUUID = try uuid(userID)
        let deviceUUID = try uuid(deviceID)
        let generation = try signed(generation)
        let sequence = try signed(highestContiguousSequence)
        try await ensureCursor(userID: userUUID, deviceID: deviceUUID)
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase,
                  let cursor = try await fetchCursor(sql: sql, userID: userUUID, deviceID: deviceUUID, lock: true)
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard cursor.state == "ready" else { throw V2SyncStoreError.resetRequired }
            guard cursor.resetGeneration == generation else { throw V2SyncStoreError.generationMismatch }
            guard let issued = try await sql.raw("""
                SELECT first_sequence, last_sequence FROM \(unsafeRaw: table("sync_receipts"))
                WHERE receipt = \(bind: receipt.rawValue) AND user_id = \(bind: userUUID) AND device_id = \(bind: deviceUUID)
                  AND reset_generation = \(bind: generation) AND expires_at > \(bind: now)
                """).first(decoding: SyncReceiptRow.self),
                sequence >= issued.firstSequence, sequence <= issued.lastSequence,
                sequence >= cursor.acknowledgedSequence
            else { throw V2SyncStoreError.invalidOrExpiredSyncReceipt }
            try await sql.raw("""
                UPDATE \(unsafeRaw: table("device_sync_cursors"))
                SET acknowledged_sequence = GREATEST(acknowledged_sequence, \(bind: sequence))
                WHERE user_id = \(bind: userUUID) AND device_id = \(bind: deviceUUID)
                """).run()
        }
    }

    public func stageReset(userID: UserID, deviceID: DeviceID, snapshot: V2SnapshotStage, now: Date) async throws -> UInt64 {
        guard !snapshot.manifestDigest.isEmpty,
              snapshot.schemaVersion > 0,
              !snapshot.capabilityProfile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !snapshot.pages.isEmpty,
              snapshot.pages.allSatisfy({ !$0.digest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(snapshot.pages.map(\.digest)).count == snapshot.pages.count,
              snapshot.expiresAt > now
        else {
            throw V2SyncStoreError.invalidSnapshot
        }
        let userUUID = try uuid(userID)
        let deviceUUID = try uuid(deviceID)
        let snapshotUUID = try uuid(snapshot.snapshotID)
        let baseSequence = try signed(snapshot.baseSequence)
        // PostgreSQL's INTEGER is signed. Do the checked conversion before
        // binding so PostgresNIO never receives an unsupported UInt32 value.
        let schemaVersion = try signedSchemaVersion(snapshot.schemaVersion)
        try await ensureCursor(userID: userUUID, deviceID: deviceUUID)
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase,
                  let cursor = try await fetchCursor(sql: sql, userID: userUUID, deviceID: deviceUUID, lock: true)
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard cursor.state == "ready" else { throw V2SyncStoreError.resetAlreadyPending }
            let watermark = try await sql.raw("SELECT COALESCE(MAX(user_sync_sequence), 0) AS value FROM \(unsafeRaw: table("user_sync_log")) WHERE user_id = \(bind: userUUID)").first(decoding: WatermarkRow.self)?.value ?? 0
            guard baseSequence <= watermark else { throw V2SyncStoreError.snapshotBeyondWatermark }
            let nextGeneration = cursor.resetGeneration + 1
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: table("sync_snapshots"))
                    (snapshot_id, user_id, device_id, reset_generation, base_user_sync_sequence,
                     manifest_digest, schema_version, capability_profile, next_sync_token, sync_receipt, expires_at, state, created_at)
                VALUES (\(bind: snapshotUUID), \(bind: userUUID), \(bind: deviceUUID), \(bind: nextGeneration), \(bind: baseSequence),
                        \(bind: snapshot.manifestDigest), \(bind: schemaVersion), \(bind: snapshot.capabilityProfile), \(bind: snapshot.nextSyncToken.rawValue), \(bind: snapshot.receipt.rawValue), \(bind: snapshot.expiresAt), 'staged', \(bind: now))
                """).run()
            for (index, page) in snapshot.pages.enumerated() {
                try await sql.raw("""
                    INSERT INTO \(unsafeRaw: table("sync_snapshot_pages")) (snapshot_id, page_index, page_digest, payload)
                    VALUES (\(bind: snapshotUUID), \(bind: index), \(bind: page.digest), \(bind: page.payload))
                    """).run()
            }
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: table("sync_tokens")) (token, user_id, device_id, reset_generation, watermark, expires_at, created_at)
                VALUES (\(bind: snapshot.nextSyncToken.rawValue), \(bind: userUUID), \(bind: deviceUUID), \(bind: nextGeneration), \(bind: baseSequence), \(bind: snapshot.expiresAt), \(bind: now))
                """).run()
            try await sql.raw("""
                UPDATE \(unsafeRaw: table("device_sync_cursors"))
                SET state = 'reset_pending', reset_generation = \(bind: nextGeneration),
                    pending_snapshot_id = \(bind: snapshotUUID), pending_base_sequence = \(bind: baseSequence),
                    pending_snapshot_expires_at = \(bind: snapshot.expiresAt)
                WHERE user_id = \(bind: userUUID) AND device_id = \(bind: deviceUUID)
                """).run()
            return try unsigned(nextGeneration)
        }
    }

    public func fetchSnapshotManifest(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID, generation: UInt64, now: Date) async throws -> V2SnapshotManifest {
        let userUUID = try uuid(userID)
        let deviceUUID = try uuid(deviceID)
        let snapshotUUID = try uuid(snapshotID)
        let generation = try signed(generation)
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase,
                  let cursor = try await fetchCursor(sql: sql, userID: userUUID, deviceID: deviceUUID, lock: true),
                  cursor.state == "reset_pending", cursor.resetGeneration == generation, cursor.pendingSnapshotID == snapshotUUID,
                  let manifest = try await sql.raw("""
                    SELECT base_user_sync_sequence, manifest_digest, schema_version, capability_profile,
                           next_sync_token, sync_receipt, expires_at
                    FROM \(unsafeRaw: table("sync_snapshots"))
                    WHERE snapshot_id = \(bind: snapshotUUID) AND user_id = \(bind: userUUID) AND device_id = \(bind: deviceUUID)
                      AND reset_generation = \(bind: generation) AND state = 'staged' AND expires_at > \(bind: now)
                    """).first(decoding: SnapshotManifestRow.self)
            else { throw V2SyncStoreError.snapshotExpiredOrInvalid }
            let pages = try await sql.raw("""
                SELECT page_digest FROM \(unsafeRaw: table("sync_snapshot_pages"))
                WHERE snapshot_id = \(bind: snapshotUUID) ORDER BY page_index
                """).all(decoding: SnapshotPageDigestRow.self)
            guard !pages.isEmpty else { throw V2SyncStoreError.snapshotExpiredOrInvalid }
            return try .init(
                snapshotID: snapshotID,
                generation: unsigned(generation),
                baseSequence: unsigned(manifest.baseSequence),
                manifestDigest: manifest.manifestDigest,
                schemaVersion: UInt32(manifest.schemaVersion),
                capabilityProfile: manifest.capabilityProfile,
                pageDigests: pages.map(\.pageDigest),
                nextSyncToken: .init(manifest.nextSyncToken),
                receipt: .init(manifest.receipt),
                expiresAt: manifest.expiresAt
            )
        }
    }

    public func fetchSnapshotPage(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID, generation: UInt64, manifestDigest: String, index: UInt32, now: Date) async throws -> V2SnapshotPage {
        let userUUID = try uuid(userID)
        let deviceUUID = try uuid(deviceID)
        let snapshotUUID = try uuid(snapshotID)
        let generation = try signed(generation)
        guard let index = Int(exactly: index) else { throw V2SyncStoreError.snapshotExpiredOrInvalid }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase,
                  let cursor = try await fetchCursor(sql: sql, userID: userUUID, deviceID: deviceUUID, lock: true),
                  cursor.state == "reset_pending", cursor.resetGeneration == generation, cursor.pendingSnapshotID == snapshotUUID,
                  let page = try await sql.raw("""
                    SELECT page_digest, payload
                    FROM \(unsafeRaw: table("sync_snapshot_pages")) AS page
                    JOIN \(unsafeRaw: table("sync_snapshots")) AS snapshot ON snapshot.snapshot_id = page.snapshot_id
                    WHERE page.snapshot_id = \(bind: snapshotUUID) AND page.page_index = \(bind: index)
                      AND snapshot.user_id = \(bind: userUUID) AND snapshot.device_id = \(bind: deviceUUID)
                      AND snapshot.reset_generation = \(bind: generation) AND snapshot.manifest_digest = \(bind: manifestDigest)
                      AND snapshot.state = 'staged' AND snapshot.expires_at > \(bind: now)
                    """).first(decoding: SnapshotPageRow.self)
            else { throw V2SyncStoreError.snapshotExpiredOrInvalid }
            return .init(snapshotID: snapshotID, generation: try unsigned(generation), manifestDigest: manifestDigest, index: UInt32(index), digest: page.digest, payload: page.payload)
        }
    }

    public func acknowledgeSnapshot(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID, generation: UInt64, baseSequence: UInt64, receipt: V2SyncReceipt, now: Date) async throws {
        let userUUID = try uuid(userID)
        let deviceUUID = try uuid(deviceID)
        let snapshotUUID = try uuid(snapshotID)
        let generation = try signed(generation)
        let base = try signed(baseSequence)
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase,
                  let cursor = try await fetchCursor(sql: sql, userID: userUUID, deviceID: deviceUUID, lock: true)
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            if cursor.state == "ready",
               cursor.resetGeneration == generation,
               cursor.completedSnapshotID == snapshotUUID,
               cursor.completedSnapshotAckReceipt == receipt.rawValue
            {
                // The first ACK has already committed the generation fence.
                // Replaying the exact authenticated ACK is a success without
                // moving the cursor again.
                return
            }
            guard cursor.state == "reset_pending" else { throw V2SyncStoreError.noResetPending }
            guard cursor.resetGeneration == generation,
                  cursor.pendingSnapshotID == snapshotUUID,
                  cursor.pendingBaseSequence == base
            else { throw V2SyncStoreError.snapshotFenceMismatch }
            guard let snapshot = try await sql.raw("""
                SELECT snapshot_id FROM \(unsafeRaw: table("sync_snapshots"))
                WHERE snapshot_id = \(bind: snapshotUUID) AND user_id = \(bind: userUUID) AND device_id = \(bind: deviceUUID)
                  AND reset_generation = \(bind: generation) AND base_user_sync_sequence = \(bind: base)
                  AND sync_receipt = \(bind: receipt.rawValue) AND state = 'staged' AND expires_at > \(bind: now)
                FOR UPDATE
                """).first(decoding: SnapshotIDRow.self)
            else { throw V2SyncStoreError.snapshotExpiredOrInvalid }
            try await sql.raw("UPDATE \(unsafeRaw: table("sync_snapshots")) SET state = 'acknowledged' WHERE snapshot_id = \(bind: snapshot.snapshotID)").run()
            try await sql.raw("""
                UPDATE \(unsafeRaw: table("device_sync_cursors"))
                SET state = 'ready', acknowledged_sequence = \(bind: base),
                    pending_snapshot_id = NULL, pending_base_sequence = NULL, pending_snapshot_expires_at = NULL,
                    completed_snapshot_id = \(bind: snapshotUUID), completed_snapshot_ack_receipt = \(bind: receipt.rawValue)
                WHERE user_id = \(bind: userUUID) AND device_id = \(bind: deviceUUID)
                """).run()
        }
    }

    private func ensureCursor(userID: UUID, deviceID: UUID) async throws {
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        try await sql.raw("""
            INSERT INTO \(unsafeRaw: table("device_sync_cursors")) (user_id, device_id, state, reset_generation)
            VALUES (\(bind: userID), \(bind: deviceID), 'ready', 1)
            ON CONFLICT (user_id, device_id) DO NOTHING
            """).run()
    }

    private func fetchCursor(sql: any SQLDatabase, userID: UUID, deviceID: UUID, lock: Bool) async throws -> DeviceCursorRow? {
        let suffix = lock ? " FOR UPDATE" : ""
        return try await sql.raw("""
            SELECT state, reset_generation, acknowledged_sequence, pending_snapshot_id, pending_base_sequence,
                   completed_snapshot_id, completed_snapshot_ack_receipt
            FROM \(unsafeRaw: table("device_sync_cursors"))
            WHERE user_id = \(bind: userID) AND device_id = \(bind: deviceID)\(unsafeRaw: suffix)
            """).first(decoding: DeviceCursorRow.self)
    }

    private func table(_ name: String) -> String { "\(schema).\(name)" }
}

public enum V2SyncStoreError: Error, Equatable, Sendable {
    case invalidRecordLimit
    case resetRequired
    case generationMismatch
    case acknowledgementBeyondWatermark
    case invalidOrExpiredSyncToken
    case invalidOrExpiredSyncReceipt
    case invalidSnapshot
    case resetAlreadyPending
    case snapshotBeyondWatermark
    case invalidSnapshotReceipt
    case noResetPending
    case snapshotFenceMismatch
    case snapshotExpiredOrInvalid
}

private struct DeviceCursorRow: Decodable {
    let state: String; let resetGeneration: Int64; let acknowledgedSequence: Int64; let pendingSnapshotID: UUID?; let pendingBaseSequence: Int64?; let completedSnapshotID: UUID?; let completedSnapshotAckReceipt: String?
    enum CodingKeys: String, CodingKey {
        case state, resetGeneration = "reset_generation", acknowledgedSequence = "acknowledged_sequence"
        case pendingSnapshotID = "pending_snapshot_id", pendingBaseSequence = "pending_base_sequence"
        case completedSnapshotID = "completed_snapshot_id", completedSnapshotAckReceipt = "completed_snapshot_ack_receipt"
    }
}
private struct SyncLogRow: Decodable {
    let sequence: Int64; let sourceEventID: UUID; let projectionKind: String; let payloadJSON: String
    enum CodingKeys: String, CodingKey { case sequence = "user_sync_sequence", sourceEventID = "source_event_id", projectionKind = "projection_kind", payloadJSON = "payload_json" }
}
private struct SyncTokenRow: Decodable { let watermark: Int64 }
private struct SyncReceiptRow: Decodable {
    let firstSequence: Int64
    let lastSequence: Int64
    enum CodingKeys: String, CodingKey { case firstSequence = "first_sequence", lastSequence = "last_sequence" }
}
private struct SnapshotMetadataRow: Decodable { let manifestDigest: String; let expiresAt: Date; enum CodingKeys: String, CodingKey { case manifestDigest = "manifest_digest", expiresAt = "expires_at" } }
private struct SnapshotManifestRow: Decodable {
    let baseSequence: Int64
    let manifestDigest: String
    let schemaVersion: Int32
    let capabilityProfile: String
    let nextSyncToken: String
    let receipt: String
    let expiresAt: Date
    enum CodingKeys: String, CodingKey {
        case baseSequence = "base_user_sync_sequence"
        case manifestDigest = "manifest_digest"
        case schemaVersion = "schema_version"
        case capabilityProfile = "capability_profile"
        case nextSyncToken = "next_sync_token"
        case receipt = "sync_receipt"
        case expiresAt = "expires_at"
    }
}
private struct SnapshotPageDigestRow: Decodable { let pageDigest: String; enum CodingKeys: String, CodingKey { case pageDigest = "page_digest" } }
private struct SnapshotPageRow: Decodable { let digest: String; let payload: Data; enum CodingKeys: String, CodingKey { case digest = "page_digest"; case payload } }
private struct WatermarkRow: Decodable { let value: Int64 }
private struct SnapshotIDRow: Decodable { let snapshotID: UUID; enum CodingKeys: String, CodingKey { case snapshotID = "snapshot_id" } }

private func uuid<Tag>(_ identifier: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag {
    guard let value = UUID(uuidString: identifier.rawValue) else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return value
}
private func signed(_ value: UInt64) throws -> Int64 {
    guard value <= UInt64(Int64.max) else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return Int64(value)
}
private func unsigned(_ value: Int64) throws -> UInt64 {
    guard value >= 0 else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return UInt64(value)
}
private func signedSchemaVersion(_ value: UInt32) throws -> Int32 {
    guard let signedValue = Int32(exactly: value), signedValue > 0 else {
        throw V2SyncStoreError.invalidSnapshot
    }
    return signedValue
}
