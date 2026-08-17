import Fluent
import Foundation
import SQLKit

public struct V2MessageProjectionStateBodyCompactionReport: Equatable, Sendable {
    public let compactedCount: Int

    public init(compactedCount: Int) {
        precondition(compactedCount >= 0)
        self.compactedCount = compactedCount
    }

    public var didWork: Bool { compactedCount > 0 }
}

/// Reclaims the duplicate canonical body for accepted revision-1 states when
/// the immutable source room event is present in the same physical schema.
///
/// Independent user shards normally do not contain that room event and keep
/// their one required inline copy. The equality and identity predicates make
/// compaction a physical representation change only; logical state identity,
/// projection authorization and wire payload remain unchanged.
public struct PostgresV2MessageProjectionStateBodyCompactionWorker: Sendable {
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

    public func runOnce(limit: Int = 100) async throws
        -> V2MessageProjectionStateBodyCompactionReport
    {
        precondition(limit > 0)
        try Task.checkCancellation()
        return try await database.transaction { database in
            guard let sql = database as? any SQLDatabase else {
                throw V2MessageProjectionStatePersistenceError.corruptPersistence
            }
            let rows = try await sql.raw("""
                WITH candidates AS MATERIALIZED (
                    SELECT state.state_id
                    FROM \(unsafeRaw: table("message_projection_states")) AS state
                    JOIN \(unsafeRaw: table("room_events")) AS event
                      ON event.event_id = state.state_event_id
                     AND event.room_id = state.room_id
                     AND event.event_type = 'message.accepted'
                     AND lower(event.payload->>'message_id') = state.message_id::text
                     AND lower(event.payload->>'room_id') = state.room_id::text
                     AND (event.payload->>'message_revision')::bigint =
                           state.message_revision
                     AND event.payload = state.payload
                    WHERE state.payload_storage = 'inline'
                      AND state.message_revision = 1
                      AND state.variant_key = 0
                      AND state.origin_event_id = state.state_event_id
                      AND NOT state.is_withdrawn
                    ORDER BY state.state_event_id, state.state_id
                    LIMIT \(bind: limit)
                    FOR UPDATE OF state SKIP LOCKED
                )
                UPDATE \(unsafeRaw: table("message_projection_states")) AS state
                SET payload = NULL,
                    payload_storage = 'room_event'
                FROM candidates
                WHERE state.state_id = candidates.state_id
                  AND state.payload_storage = 'inline'
                RETURNING state.state_id
                """).all(decoding: CompactedStateRow.self)
            return .init(compactedCount: rows.count)
        }
    }

    private func table(_ name: String) -> String { "\(schema).\(name)" }
}

private struct CompactedStateRow: Decodable {
    let stateID: UUID

    private enum CodingKeys: String, CodingKey {
        case stateID = "state_id"
    }
}
