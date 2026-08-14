import Fluent
import Foundation
import IMV2Core
import SQLKit

public struct V2UserSyncLogCompactionReport: Equatable, Sendable {
    public let claimedUserCount: Int
    public let deletedLogRowCount: Int
    public let deletedSharedPayloadCount: Int
    public init(
        claimedUserCount: Int,
        deletedLogRowCount: Int,
        deletedSharedPayloadCount: Int
    ) {
        self.claimedUserCount = claimedUserCount
        self.deletedLogRowCount = deletedLogRowCount
        self.deletedSharedPayloadCount = deletedSharedPayloadCount
    }
    public var didWork: Bool {
        deletedLogRowCount > 0 || deletedSharedPayloadCount > 0
    }
}

/// Advances one user's retained floor in a bounded transaction. The selected
/// floor is no newer than the canonical projection checkpoint and no newer
/// than any valid incremental token/receipt. Device recovery is deliberately
/// lazy: pull serializes on this retention row and stages a shared checkpoint
/// artifact only when an active low-watermark device actually reconnects.
public struct PostgresV2UserSyncLogCompactionWorker: Sendable {
    private let database: any Database
    private let schema: String
    private let minimumLogAge: TimeInterval

    public init(
        database: any Database,
        schema: String = "im_v2",
        minimumLogAge: TimeInterval = 7 * 86_400
    ) {
        precondition(minimumLogAge.isFinite && minimumLogAge > 0)
        precondition(schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil)
        self.database = database
        self.schema = schema
        self.minimumLogAge = minimumLogAge
    }

    public func runOnce(
        now: Date = Date(),
        userLimit: Int = 8,
        rowLimit: Int = 500
    ) async throws -> V2UserSyncLogCompactionReport {
        guard userLimit > 0, rowLimit > 0 else {
            throw V2UserSyncLogCompactionError.invalidLimit
        }
        var report = V2UserSyncLogCompactionReport(
            claimedUserCount: 0,
            deletedLogRowCount: 0, deletedSharedPayloadCount: 0
        )
        for _ in 0 ..< userLimit {
            try Task.checkCancellation()
            guard let pass = try await compactOne(now: now, rowLimit: rowLimit) else { break }
            report = .init(
                claimedUserCount: report.claimedUserCount + 1,
                deletedLogRowCount: report.deletedLogRowCount + pass.deletedLogRowCount,
                deletedSharedPayloadCount: report.deletedSharedPayloadCount + pass.deletedSharedPayloadCount
            )
        }
        return report
    }

    private func compactOne(now: Date, rowLimit: Int) async throws -> CompactionPass? {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2UserSyncLogCompactionError.corruptPersistence
            }
            guard let candidate = try await sql.raw("""
                SELECT checkpoint.user_id, checkpoint.projected_sequence,
                       retention.compacted_through_sequence
                FROM \(unsafeRaw: table("user_sync_retention")) AS retention
                JOIN \(unsafeRaw: table("user_projection_checkpoints")) AS checkpoint
                  ON checkpoint.user_id = retention.user_id
                WHERE checkpoint.state = 'ready'
                  AND (
                      checkpoint.projected_sequence >
                          retention.compacted_through_sequence
                      OR EXISTS (
                          SELECT 1 FROM \(unsafeRaw: table("user_sync_log")) AS prefix
                          WHERE prefix.user_id = checkpoint.user_id
                            AND prefix.user_sync_sequence <=
                                retention.compacted_through_sequence
                      )
                  )
                  AND (checkpoint.migration_fence_expires_at IS NULL
                       OR checkpoint.migration_fence_expires_at <= \(bind: now))
                ORDER BY retention.updated_at, retention.user_id
                FOR UPDATE OF checkpoint, retention SKIP LOCKED
                LIMIT 1
                """).first(decoding: CompactionCandidateRow.self)
            else { return nil }

            // Current generation capabilities can still ask for their exact
            // old watermark. Keep the floor behind every unexpired one.
            let protected = try await sql.raw("""
                SELECT MIN(value) AS value
                FROM (
                    SELECT token.watermark AS value
                    FROM \(unsafeRaw: table("sync_tokens")) AS token
                    WHERE token.user_id = \(bind: candidate.userID)
                      AND token.expires_at > \(bind: now)
                    UNION ALL
                    -- An incremental receipt authorizes ACK of its inclusive
                    -- first sequence. Keep that row itself until the receipt
                    -- expires; only the prefix strictly before it is safe.
                    SELECT GREATEST(receipt.first_sequence - 1, 0)
                    FROM \(unsafeRaw: table("sync_receipts")) AS receipt
                    WHERE receipt.user_id = \(bind: candidate.userID)
                      AND receipt.expires_at > \(bind: now)
                ) AS capability
            """).first(decoding: OptionalCompactionFloorRow.self)?.value
            // Keep a durable replay window for higher-level operation workers
            // that may re-read a freshly appended effect before advancing
            // their own checkpoint. This also spans the default shard rollback
            // and capability lifetimes; compaction is still bounded by rate ×
            // window rather than total account age.
            let recentFloor = try await sql.raw("""
                SELECT MIN(user_sync_sequence) - 1 AS value
                FROM \(unsafeRaw: table("user_sync_log"))
                WHERE user_id = \(bind: candidate.userID)
                  AND created_at > \(bind: now.addingTimeInterval(-minimumLogAge))
                """).first(decoding: OptionalCompactionFloorRow.self)?.value
            let safeFloor = min(
                candidate.projectedSequence,
                protected ?? candidate.projectedSequence,
                recentFloor ?? candidate.projectedSequence
            )
            let floor = max(candidate.compactedThroughSequence, safeFloor)
            guard floor > 0 else {
                // Move the row behind peers instead of reclaiming it in a hot
                // loop while a capability legitimately protects the prefix.
                try await sql.raw("""
                    UPDATE \(unsafeRaw: table("user_sync_retention"))
                    SET updated_at = \(bind: now)
                    WHERE user_id = \(bind: candidate.userID)
                    """).run()
                return .init()
            }

            // Publish the floor before deleting any prefix row. Pull takes a
            // shared lock on this row before reading incremental history, so it
            // either completes against the old floor or observes the new floor
            // and enters snapshot recovery. No maintenance pass scans a user's
            // unbounded historical device set.
            // A bounded pass may leave physical rows at/below the floor; they
            // are unreachable incremental history and a later pass reclaims
            // them without changing protocol state.
            if floor > candidate.compactedThroughSequence {
                try await sql.raw("""
                    UPDATE \(unsafeRaw: table("user_sync_retention"))
                    SET compacted_through_sequence = \(bind: floor),
                        updated_at = \(bind: now)
                    WHERE user_id = \(bind: candidate.userID)
                    """).run()
            }

            let deleted = try await sql.raw("""
                WITH candidates AS (
                    SELECT ctid, source_event_id, projection_kind
                    FROM \(unsafeRaw: table("user_sync_log"))
                    WHERE user_id = \(bind: candidate.userID)
                      AND user_sync_sequence <= \(bind: floor)
                    ORDER BY user_sync_sequence
                    LIMIT \(bind: rowLimit)
                    FOR UPDATE SKIP LOCKED
                ), removed AS (
                    DELETE FROM \(unsafeRaw: table("user_sync_log")) AS log
                    USING candidates
                    WHERE log.ctid = candidates.ctid
                    RETURNING candidates.source_event_id,
                              candidates.projection_kind
                )
                SELECT source_event_id, projection_kind FROM removed
                """).all(decoding: CompactedPayloadKeyRow.self)
            var deletedPayloads = 0
            for key in Set(deleted) {
                deletedPayloads += try await sql.raw("""
                    DELETE FROM \(unsafeRaw: table("fanout_sync_payloads")) AS payload
                    WHERE payload.source_event_id = \(bind: key.sourceEventID)
                      AND payload.projection_kind = \(bind: key.projectionKind)
                      AND NOT EXISTS (
                          SELECT 1 FROM \(unsafeRaw: table("user_sync_log")) AS log
                          WHERE log.source_event_id = payload.source_event_id
                            AND log.projection_kind = payload.projection_kind
                            AND log.payload_storage = 'fanout_shared'
                      )
                    RETURNING 1 AS value
                    """).all(decoding: CompactionExistsRow.self).count
            }
            return .init(
                deletedLogRowCount: deleted.count,
                deletedSharedPayloadCount: deletedPayloads
            )
        }
    }

    private func table(_ name: String) -> String { "\(schema).\(name)" }
}

public enum V2UserSyncLogCompactionError: Error, Equatable, Sendable {
    case invalidLimit
    case corruptPersistence
}

private struct CompactionPass {
    let deletedLogRowCount: Int
    let deletedSharedPayloadCount: Int
    init(deletedLogRowCount: Int = 0, deletedSharedPayloadCount: Int = 0) {
        self.deletedLogRowCount = deletedLogRowCount
        self.deletedSharedPayloadCount = deletedSharedPayloadCount
    }
}
private struct CompactionCandidateRow: Decodable {
    let userID: UUID
    let projectedSequence: Int64
    let compactedThroughSequence: Int64
    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case projectedSequence = "projected_sequence"
        case compactedThroughSequence = "compacted_through_sequence"
    }
}
private struct OptionalCompactionFloorRow: Decodable { let value: Int64? }
private struct CompactedPayloadKeyRow: Decodable, Hashable {
    let sourceEventID: UUID
    let projectionKind: String
    enum CodingKeys: String, CodingKey {
        case sourceEventID = "source_event_id"
        case projectionKind = "projection_kind"
    }
}
private struct CompactionExistsRow: Decodable { let value: Int }
