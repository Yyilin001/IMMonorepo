import Fluent
import Foundation
import SQLKit

/// Deletes only immutable states that are older than the safety grace, have
/// no user/fan-out reference, and are not the control store's current active
/// message revision. RESTRICT foreign keys are the final race-safe fence.
public struct PostgresV2MessageProjectionStateGCWorker: Sendable {
    private let database: any Database
    private let schema: String
    private let retention: TimeInterval

    public init(
        database: any Database,
        schema: String = "im_v2",
        retention: TimeInterval
    ) {
        precondition(
            schema.range(
                of: "^[A-Za-z_][A-Za-z0-9_]*$",
                options: .regularExpression
            ) != nil
        )
        precondition(retention.isFinite && retention > 0)
        self.database = database
        self.schema = schema
        self.retention = retention
    }

    @discardableResult
    public func runOnce(now: Date = Date(), limit: Int = 500) async throws -> Int {
        guard limit > 0 else { throw V2MessageProjectionStateGCError.invalidLimit }
        try Task.checkCancellation()
        guard let cutoff = v2PostgresPastTimestamp(now: now, interval: retention) else {
            throw V2MessageProjectionStateGCError.corruptPersistence
        }
        guard let sql = database as? any SQLDatabase else {
            throw V2MessageProjectionStateGCError.corruptPersistence
        }
        return try await sql.raw("""
            WITH candidates AS (
                SELECT state.state_id
                FROM \(unsafeRaw: table("message_projection_states")) AS state
                WHERE state.created_at < \(bind: cutoff)
                  AND NOT EXISTS (
                      SELECT 1
                      FROM \(unsafeRaw: table("user_projection_versions")) AS version
                      WHERE version.message_state_id = state.state_id
                  )
                  AND NOT EXISTS (
                      SELECT 1
                      FROM \(unsafeRaw: table("fanout_sync_payloads")) AS shared
                      WHERE shared.message_state_id = state.state_id
                  )
                  AND NOT EXISTS (
                      SELECT 1
                      FROM \(unsafeRaw: table("messages")) AS message
                      WHERE message.message_id = state.message_id
                        AND message.content_revision = state.message_revision
                        AND message.withdrawn_at IS NULL
                  )
                ORDER BY state.created_at, state.state_id
                LIMIT \(bind: limit)
                FOR UPDATE OF state SKIP LOCKED
            )
            DELETE FROM \(unsafeRaw: table("message_projection_states")) AS state
            USING candidates
            WHERE state.state_id = candidates.state_id
            RETURNING 1 AS value
            """).all(decoding: MessageProjectionStateGCDeletedRow.self).count
    }

    private func table(_ name: String) -> String { "\(schema).\(name)" }
}

public enum V2MessageProjectionStateGCError: Error, Equatable, Sendable {
    case invalidLimit
    case corruptPersistence
}

private struct MessageProjectionStateGCDeletedRow: Decodable { let value: Int }
