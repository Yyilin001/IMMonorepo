import Fluent
import Foundation
import SQLKit

public struct V2FanoutPayloadReferenceBackfillReport: Equatable, Sendable {
    public let linkedRowCount: Int
    public let compactedRowCount: Int

    public var didWork: Bool { linkedRowCount > 0 || compactedRowCount > 0 }
}

/// Converts accepted-message fan-out bodies into references to the exact
/// immutable message state. Edit, withdrawal, moderation and all other delta
/// payloads remain inline because replacing those deltas with a folded state
/// would change incremental-sync semantics.
public struct PostgresV2FanoutPayloadReferenceBackfillWorker: Sendable {
    private let database: any Database
    private let schema: String

    public init(database: any Database, schema: String = "im_v2") {
        precondition(
            schema.range(
                of: "^[A-Za-z_][A-Za-z0-9_]*$",
                options: .regularExpression
            ) != nil
        )
        self.database = database
        self.schema = schema
    }

    public func runOnce(limit: Int = 100) async throws -> V2FanoutPayloadReferenceBackfillReport {
        guard limit > 0 else { throw V2FanoutPayloadReferenceBackfillError.invalidLimit }
        try Task.checkCancellation()
        return try await database.transaction { database in
            guard let sql = database as? any SQLDatabase else {
                throw V2FanoutPayloadReferenceBackfillError.corruptPersistence
            }
            let rows = try await sql.raw("""
                WITH candidates AS MATERIALIZED (
                    SELECT shared.ctid, state.state_id,
                           (shared.message_state_id IS NULL) AS linked,
                           (shared.payload IS NOT NULL) AS compacted
                    FROM \(unsafeRaw: table("fanout_sync_payloads")) AS shared
                    JOIN \(unsafeRaw: table("room_events")) AS event
                      ON event.event_id = shared.source_event_id
                     AND event.event_type = 'message.accepted'
                    JOIN \(unsafeRaw: table("message_projection_states")) AS state
                      ON state.state_event_id = event.event_id
                     AND state.variant_key = 0
                    WHERE shared.projection_kind = 'message'
                      AND (shared.message_state_id IS NULL OR shared.payload IS NOT NULL)
                      AND shared.payload IS NOT NULL
                      AND shared.payload = state.payload
                    ORDER BY shared.source_event_id
                    LIMIT \(bind: limit)
                    FOR UPDATE OF shared SKIP LOCKED
                )
                UPDATE \(unsafeRaw: table("fanout_sync_payloads")) AS shared
                SET message_state_id = candidates.state_id,
                    payload = NULL
                FROM candidates
                WHERE shared.ctid = candidates.ctid
                RETURNING candidates.linked, candidates.compacted
                """).all(decoding: FanoutPayloadBackfillMutationRow.self)
            return .init(
                linkedRowCount: rows.lazy.filter(\.linked).count,
                compactedRowCount: rows.lazy.filter(\.compacted).count
            )
        }
    }

    private func table(_ name: String) -> String { "\(schema).\(name)" }
}

public enum V2FanoutPayloadReferenceBackfillError: Error, Equatable, Sendable {
    case invalidLimit
    case corruptPersistence
}

private struct FanoutPayloadBackfillMutationRow: Decodable {
    let linked: Bool
    let compacted: Bool
}
