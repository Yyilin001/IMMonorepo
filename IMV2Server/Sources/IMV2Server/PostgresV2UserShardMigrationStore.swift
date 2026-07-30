import Fluent
import Foundation
import IMV2Core
import SQLKit

/// PostgreSQL implementation of the migration control record. Each mutation
/// locks exactly one migration row, so concurrent workers cannot turn a late
/// copy/verify result into a route-ready state.
public struct PostgresV2UserShardMigrationStore: V2UserShardMigrationStoring {
    private let database: any Database
    private let makeUUID: @Sendable () -> UUID

    public init(database: any Database, makeUUID: @escaping @Sendable () -> UUID = UUID.init) {
        self.database = database
        self.makeUUID = makeUUID
    }

    public func prepare(_ request: V2UserShardMigrationPreparation, now: Date) async throws -> V2UserShardMigrationRecord {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            if let existing = try await select(userID: request.userID, forUpdate: true, sql: sql) {
                guard existing.matches(request) else { throw V2UserShardMigrationStoreError.requestConflict }
                return try existing.record()
            }
            try await sql.raw("""
                INSERT INTO im_v2.user_shard_migrations
                    (migration_id, user_id, source_bucket, target_bucket, source_router_epoch, phase, created_at, updated_at)
                VALUES
                    (\(bind: request.migrationID), \(bind: try userUUID(request.userID)), \(bind: request.sourceBucket), \(bind: request.targetBucket),
                     \(bind: request.sourceRouterEpoch), 'prepared', \(bind: now), \(bind: now))
                """).run()
            guard let created = try await select(migrationID: request.migrationID, forUpdate: false, sql: sql) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            return try created.record()
        }
    }

    public func load(migrationID: UUID) async throws -> V2UserShardMigrationRecord? {
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return try await select(migrationID: migrationID, forUpdate: false, sql: sql)?.record()
    }

    public func load(userID: UserID) async throws -> V2UserShardMigrationRecord? {
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return try await select(userID: userID, forUpdate: false, sql: sql)?.record()
    }

    /// Fetches the current control records for a bounded delivery batch. The
    /// result deliberately omits users with no active migration, which is the
    /// common case; callers must still treat the returned phase as a routing
    /// snapshot and retain the existing migration fences for writes.
    public func load(userIDs: [UserID]) async throws -> [UserID: V2UserShardMigrationRecord] {
        guard !userIDs.isEmpty else { return [:] }
        let rawUserIDs = try userIDs.map(userUUID)
        guard Set(rawUserIDs).count == rawUserIDs.count else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let inputJSON = try migrationJSON(rawUserIDs.map(\.uuidString))
        let rows = try await sql.raw("""
            WITH input AS (
                SELECT value::uuid AS user_id
                FROM jsonb_array_elements_text(\(bind: inputJSON)::jsonb) AS values(value)
            )
            SELECT migration.migration_id, migration.user_id, migration.source_bucket,
                   migration.target_bucket, migration.source_router_epoch, migration.phase,
                   migration.source_fingerprint, migration.target_fingerprint,
                   migration.verified_at, migration.last_error_code,
                   migration.cutover_operation_id, migration.retention_until
            FROM im_v2.user_shard_migrations AS migration
            JOIN input USING (user_id)
            """).all(decoding: V2PostgresUserShardMigrationRow.self)
        var records: [UserID: V2UserShardMigrationRecord] = [:]
        for row in rows {
            let record = try row.record()
            guard records[record.userID] == nil else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            records[record.userID] = record
        }
        return records
    }

    public func advance(
        migrationID: UUID,
        expectedPhase: V2UserShardMigrationPhase,
        action: V2UserShardMigrationAction,
        fingerprints: (source: String, target: String)?,
        now: Date
    ) async throws -> V2UserShardMigrationRecord {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard let current = try await select(migrationID: migrationID, forUpdate: true, sql: sql) else {
                throw V2UserShardMigrationStoreError.recordNotFound
            }
            guard current.phase == expectedPhase else { throw V2UserShardMigrationStoreError.phaseConflict }
            let next = try V2UserShardMigrationStateMachine.transition(from: current.phase, by: action)
            let shouldPersistFingerprints = action == .verificationSucceeded || action == .forwardingVerificationSucceeded
            if shouldPersistFingerprints {
                guard let fingerprints, validFingerprint(fingerprints.source), fingerprints.source == fingerprints.target else {
                    throw V2UserShardMigrationStoreError.invalidFingerprint
                }
            } else if fingerprints != nil {
                throw V2UserShardMigrationStoreError.invalidFingerprint
            }
            let source = shouldPersistFingerprints ? fingerprints!.source : current.sourceFingerprint
            let target = shouldPersistFingerprints ? fingerprints!.target : current.targetFingerprint
            let verifiedAt: Date? = shouldPersistFingerprints ? now : current.verifiedAt
            try await sql.raw("""
                UPDATE im_v2.user_shard_migrations
                SET phase = \(bind: next.rawValue),
                    source_fingerprint = \(bind: source),
                    target_fingerprint = \(bind: target),
                    verified_at = \(bind: verifiedAt),
                    last_error_code = NULL,
                    updated_at = \(bind: now)
                WHERE migration_id = \(bind: migrationID)
                """).run()
            return try current.record(
                phase: next, sourceFingerprint: source, targetFingerprint: target,
                verifiedAt: verifiedAt, lastErrorCodeOverride: .some(nil)
            )
        }
    }

    public func fail(
        migrationID: UUID,
        expectedPhase: V2UserShardMigrationPhase,
        code: V2UserShardMigrationFailureCode,
        now: Date
    ) async throws -> V2UserShardMigrationRecord {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard let current = try await select(migrationID: migrationID, forUpdate: true, sql: sql) else {
                throw V2UserShardMigrationStoreError.recordNotFound
            }
            guard current.phase == expectedPhase else { throw V2UserShardMigrationStoreError.phaseConflict }
            let next = try V2UserShardMigrationStateMachine.transition(from: current.phase, by: .fail)
            try await sql.raw("""
                UPDATE im_v2.user_shard_migrations
                SET phase = \(bind: next.rawValue), last_error_code = \(bind: code.rawValue), updated_at = \(bind: now)
                WHERE migration_id = \(bind: migrationID)
                """).run()
            return try current.record(phase: next, lastErrorCodeOverride: .some(code))
        }
    }

    private func select(migrationID: UUID, forUpdate: Bool, sql: any SQLDatabase) async throws -> V2PostgresUserShardMigrationRow? {
        try await sql.raw("""
            SELECT migration_id, user_id, source_bucket, target_bucket, source_router_epoch, phase,
                   source_fingerprint, target_fingerprint, verified_at, last_error_code,
                   cutover_operation_id, retention_until
            FROM im_v2.user_shard_migrations
            WHERE migration_id = \(bind: migrationID)
            \(unsafeRaw: forUpdate ? "FOR UPDATE" : "")
            """).first(decoding: V2PostgresUserShardMigrationRow.self)
    }

    private func select(userID: UserID, forUpdate: Bool, sql: any SQLDatabase) async throws -> V2PostgresUserShardMigrationRow? {
        try await sql.raw("""
            SELECT migration_id, user_id, source_bucket, target_bucket, source_router_epoch, phase,
                   source_fingerprint, target_fingerprint, verified_at, last_error_code,
                   cutover_operation_id, retention_until
            FROM im_v2.user_shard_migrations
            WHERE user_id = \(bind: try userUUID(userID))
            \(unsafeRaw: forUpdate ? "FOR UPDATE" : "")
            """).first(decoding: V2PostgresUserShardMigrationRow.self)
    }
}

private func migrationJSON<T: Encodable>(_ value: T) throws -> String {
    let data = try JSONEncoder().encode(value)
    guard let json = String(data: data, encoding: .utf8) else {
        throw V2RoomWriteStoreError.corruptPersistenceState
    }
    return json
}

extension PostgresV2UserShardMigrationStore: V2UserShardMigrationRetentionStoring {
    public func claimExpiredRetention(now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2UserShardMigrationRetentionLease] {
        guard leaseDuration > 0, limit > 0 else { return [] }
        let token = makeUUID()
        let expiry = now.addingTimeInterval(leaseDuration)
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let rows = try await sql.raw("""
                WITH candidates AS (
                    SELECT migration_id
                    FROM im_v2.user_shard_migrations
                    WHERE phase = 'retention' AND retention_until <= \(bind: now)
                      AND (retention_claim_expires_at IS NULL OR retention_claim_expires_at <= \(bind: now))
                    ORDER BY retention_until, migration_id
                    LIMIT \(bind: limit)
                    FOR UPDATE SKIP LOCKED
                )
                UPDATE im_v2.user_shard_migrations AS migration
                SET retention_claim_token = \(bind: token),
                    retention_claim_expires_at = \(bind: expiry),
                    retention_retry_count = migration.retention_retry_count + 1,
                    updated_at = \(bind: now)
                FROM candidates
                WHERE migration.migration_id = candidates.migration_id
                RETURNING migration.migration_id, migration.user_id, migration.source_bucket, migration.target_bucket,
                          migration.source_router_epoch, migration.phase, migration.source_fingerprint,
                          migration.target_fingerprint, migration.verified_at, migration.last_error_code,
                          migration.cutover_operation_id, migration.retention_until
                """).all(decoding: V2PostgresUserShardMigrationRow.self)
            return try rows.map { .init(record: try $0.record(), claimToken: token) }
        }
    }

    public func completeRetention(_ lease: V2UserShardMigrationRetentionLease, now: Date) async throws -> Bool {
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let completed = try V2UserShardMigrationStateMachine.transition(from: .retention, by: .complete)
        return try await sql.raw("""
            UPDATE im_v2.user_shard_migrations
            SET phase = \(bind: completed.rawValue),
                retention_claim_token = NULL, retention_claim_expires_at = NULL,
                updated_at = \(bind: now)
            WHERE migration_id = \(bind: lease.record.migrationID)
              AND phase = 'retention' AND retention_claim_token = \(bind: lease.claimToken)
            RETURNING migration_id
            """).first(decoding: V2MigrationIDRow.self) != nil
    }
}

private struct V2PostgresUserShardMigrationRow: Decodable {
    let migrationID: UUID
    let userID: UUID
    let sourceBucket: String
    let targetBucket: String
    let sourceRouterEpoch: Int64
    let phase: V2UserShardMigrationPhase
    let sourceFingerprint: String?
    let targetFingerprint: String?
    let verifiedAt: Date?
    let lastErrorCode: V2UserShardMigrationFailureCode?
    let cutoverOperationID: UUID?
    let retentionUntil: Date?

    enum CodingKeys: String, CodingKey {
        case migrationID = "migration_id", userID = "user_id", sourceBucket = "source_bucket", targetBucket = "target_bucket"
        case sourceRouterEpoch = "source_router_epoch", phase, sourceFingerprint = "source_fingerprint", targetFingerprint = "target_fingerprint"
        case verifiedAt = "verified_at", lastErrorCode = "last_error_code"
        case cutoverOperationID = "cutover_operation_id", retentionUntil = "retention_until"
    }

    func matches(_ request: V2UserShardMigrationPreparation) -> Bool {
        migrationID == request.migrationID && sourceBucket == request.sourceBucket && targetBucket == request.targetBucket && sourceRouterEpoch == request.sourceRouterEpoch
    }

    func record(
        phase: V2UserShardMigrationPhase? = nil,
        sourceFingerprint: String? = nil,
        targetFingerprint: String? = nil,
        verifiedAt: Date? = nil,
        lastErrorCodeOverride: V2UserShardMigrationFailureCode?? = nil
    ) throws -> V2UserShardMigrationRecord {
        try .init(
            migrationID: migrationID, userID: .init(userID.uuidString), sourceBucket: sourceBucket, targetBucket: targetBucket,
            sourceRouterEpoch: sourceRouterEpoch, phase: phase ?? self.phase,
            sourceFingerprint: sourceFingerprint ?? self.sourceFingerprint,
            targetFingerprint: targetFingerprint ?? self.targetFingerprint,
            verifiedAt: verifiedAt ?? self.verifiedAt,
            lastErrorCode: lastErrorCodeOverride ?? self.lastErrorCode,
            cutoverOperationID: cutoverOperationID,
            retentionUntil: retentionUntil
        )
    }
}

private struct V2MigrationIDRow: Decodable {
    let migrationID: UUID
    enum CodingKeys: String, CodingKey { case migrationID = "migration_id" }
}

private func userUUID(_ userID: UserID) throws -> UUID {
    guard let parsed = UUID(uuidString: userID.rawValue) else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return parsed
}

private func validFingerprint(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 256 && value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
}
