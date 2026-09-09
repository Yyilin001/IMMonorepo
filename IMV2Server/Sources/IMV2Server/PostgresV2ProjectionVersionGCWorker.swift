import Fluent
import Foundation
import SQLKit

/// Reclaims closed application-MVCC versions without invalidating a snapshot
/// artifact that is still reading at its fixed base sequence. Published
/// artifacts are self-contained, so only active builders retain history.
public struct PostgresV2ProjectionVersionGCWorker: Sendable {
    private let database: any Database
    private let schema: String

    public init(database: any Database, schema: String = "im_v2") {
        precondition(schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil)
        self.database = database
        self.schema = schema
    }

    @discardableResult
    public func runOnce(now: Date = Date(), limit: Int = 500) async throws -> Int {
        guard limit > 0 else { throw V2ProjectionVersionGCError.invalidLimit }
        try Task.checkCancellation()
        guard v2PostgresTimestampCanEncode(now) else { throw V2ProjectionVersionGCError.corruptPersistence }
        guard let sql = database as? any SQLDatabase else {
            throw V2ProjectionVersionGCError.corruptPersistence
        }
        return try await sql.raw("""
            WITH candidates AS (
                SELECT version.ctid
                FROM \(unsafeRaw: table("user_projection_versions")) AS version
                WHERE version.valid_to_sequence IS NOT NULL
                  AND NOT EXISTS (
                      SELECT 1
                      FROM \(unsafeRaw: table("user_projection_checkpoints")) AS checkpoint
                      WHERE checkpoint.user_id = version.user_id
                        AND checkpoint.migration_fence_expires_at > \(bind: now)
                  )
                  AND NOT EXISTS (
                      SELECT 1
                      FROM \(unsafeRaw: table("sync_snapshot_artifacts")) AS artifact
                      WHERE artifact.user_id = version.user_id
                        AND artifact.state = 'building'
                        AND artifact.expires_at > \(bind: now)
                        AND artifact.base_user_sync_sequence >= version.valid_from_sequence
                        AND artifact.base_user_sync_sequence < version.valid_to_sequence
                  )
                ORDER BY version.valid_to_sequence, version.user_id,
                         version.projection_kind, version.entity_key
                LIMIT \(bind: limit)
                FOR UPDATE SKIP LOCKED
            )
            DELETE FROM \(unsafeRaw: table("user_projection_versions")) AS version
            USING candidates
            WHERE version.ctid = candidates.ctid
            RETURNING 1 AS value
            """).all(decoding: ProjectionVersionGCDeletedRow.self).count
    }

    private func table(_ name: String) -> String { "\(schema).\(name)" }
}

public enum V2ProjectionVersionGCError: Error, Equatable, Sendable {
    case invalidLimit
    case corruptPersistence
}

private struct ProjectionVersionGCDeletedRow: Decodable { let value: Int }
