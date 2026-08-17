import Fluent
import Foundation
import SQLKit

public struct V2MessageProjectionBackfillReport: Equatable, Sendable {
    public let linkedRowCount: Int
    public let compactedRowCount: Int

    public var didWork: Bool { linkedRowCount > 0 || compactedRowCount > 0 }
}

/// Incrementally converts legacy per-user message payloads into references to
/// immutable shard-local message states. Rows stay readable throughout the
/// expand migration: dual mode retains their inline payload, while shared mode
/// removes it only after the state insert has been verified in the same
/// transaction.
public struct PostgresV2MessageProjectionBackfillWorker: Sendable {
    private let database: any Database
    private let schema: String
    private let compactInlinePayloads: Bool

    public init(
        database: any Database,
        schema: String = "im_v2",
        compactInlinePayloads: Bool = false
    ) {
        precondition(
            schema.range(
                of: "^[A-Za-z_][A-Za-z0-9_]*$",
                options: .regularExpression
            ) != nil
        )
        self.database = database
        self.schema = schema
        self.compactInlinePayloads = compactInlinePayloads
    }

    public func runOnce(
        now: Date = Date(),
        limit: Int = 100
    ) async throws -> V2MessageProjectionBackfillReport {
        guard limit > 0 else { throw V2MessageProjectionBackfillError.invalidLimit }
        try Task.checkCancellation()
        return try await database.transaction { database in
            guard let sql = database as? any SQLDatabase else {
                throw V2MessageProjectionBackfillError.corruptPersistence
            }
            let rows = try await sql.raw("""
                SELECT version.user_id, version.entity_key,
                       version.valid_from_sequence, version.source_event_id,
                       version.scope_room_id, version.message_state_id,
                       version.payload::text AS payload_json, version.created_at,
                       state.payload::text AS state_payload_json
                FROM \(unsafeRaw: table("user_projection_versions")) AS version
                LEFT JOIN \(unsafeRaw: table("message_projection_states")) AS state
                  ON state.state_id = version.message_state_id
                WHERE version.projection_kind = 'message'
                  AND version.payload IS NOT NULL
                  AND (
                      version.message_state_id IS NULL
                      OR \(bind: compactInlinePayloads)
                  )
                  AND NOT EXISTS (
                      SELECT 1
                      FROM \(unsafeRaw: table("user_projection_checkpoints")) AS checkpoint
                      WHERE checkpoint.user_id = version.user_id
                        AND checkpoint.migration_fence_expires_at > \(bind: now)
                  )
                ORDER BY version.user_id, version.entity_key,
                         version.valid_from_sequence
                LIMIT \(bind: limit)
                FOR UPDATE OF version SKIP LOCKED
                """).all(decoding: MessageProjectionBackfillRow.self)
            guard !rows.isEmpty else {
                return .init(linkedRowCount: 0, compactedRowCount: 0)
            }

            let repository = PostgresV2MessageProjectionStateRepository(schema: schema)
            var linked = 0
            var compacted = 0
            for row in rows {
                try Task.checkCancellation()
                let stateID: UUID
                if let existingStateID = row.messageStateID {
                    guard compactInlinePayloads,
                          row.statePayloadJSON == row.payloadJSON
                    else { throw V2MessageProjectionBackfillError.conflictingState }
                    stateID = existingStateID
                } else {
                    guard let payloadJSON = row.payloadJSON,
                          let messageID = UUID(uuidString: row.entityKey),
                          let roomID = row.roomID
                    else { throw V2MessageProjectionBackfillError.invalidLegacyPayload }
                    let state: V2MessageProjectionState
                    do {
                        state = try .init(payloadJSON: payloadJSON)
                    } catch {
                        throw V2MessageProjectionBackfillError.invalidLegacyPayload
                    }
                    guard UUID(uuidString: state.messageID.rawValue) == messageID,
                          UUID(uuidString: state.roomID.rawValue) == roomID,
                          state.messageRevision <= UInt64(Int64.max)
                    else { throw V2MessageProjectionBackfillError.invalidLegacyPayload }
                    let stateEventID = state.messageRevision == 1 ? row.sourceEventID : nil
                    let stored = try V2StoredMessageProjectionState(
                        state: state,
                        originEventID: row.sourceEventID,
                        stateEventID: stateEventID,
                        createdAt: row.createdAt
                    )
                    try await repository.persist(stored, sql: sql)
                    stateID = stored.stateID
                    linked += 1
                }

                try await sql.raw("""
                    UPDATE \(unsafeRaw: table("user_projection_versions"))
                    SET message_state_id = \(bind: stateID),
                        payload = CASE
                            WHEN \(bind: compactInlinePayloads) THEN NULL
                            ELSE payload
                        END
                    WHERE user_id = \(bind: row.userID)
                      AND projection_kind = 'message'
                      AND entity_key = \(bind: row.entityKey)
                      AND valid_from_sequence = \(bind: row.validFromSequence)
                    """).run()
                if compactInlinePayloads { compacted += 1 }
            }
            return .init(linkedRowCount: linked, compactedRowCount: compacted)
        }
    }

    private func table(_ name: String) -> String { "\(schema).\(name)" }
}

public enum V2MessageProjectionBackfillError: Error, Equatable, Sendable {
    case invalidLimit
    case corruptPersistence
    case invalidLegacyPayload
    case conflictingState
}

private struct MessageProjectionBackfillRow: Decodable {
    let userID: UUID
    let entityKey: String
    let validFromSequence: Int64
    let sourceEventID: UUID
    let roomID: UUID?
    let messageStateID: UUID?
    let payloadJSON: String?
    let createdAt: Date
    let statePayloadJSON: String?
    enum CodingKeys: String, CodingKey {
        case userID = "user_id", entityKey = "entity_key"
        case validFromSequence = "valid_from_sequence"
        case sourceEventID = "source_event_id", roomID = "scope_room_id"
        case messageStateID = "message_state_id", payloadJSON = "payload_json"
        case createdAt = "created_at", statePayloadJSON = "state_payload_json"
    }
}
