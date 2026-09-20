import Fluent
import Foundation
import IMV2Core
import SQLKit

/// 用户事件的目标事务；不读取房间日志，也不依赖扇出载荷、计划或完成单元。
public struct PostgresV2UserStateEventProjector: V2UserStateEventProjecting {
    private let database: any Database
    private let schema: String

    public init(database: any Database, schema: String = "im_v2") throws {
        guard schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
            throw V2UserStateEventError.invalidEvent
        }
        self.database = database
        self.schema = schema
    }

    /// 接收回执保留在日志压缩之外，响应丢失或源端确认失败不会再次分配序号。
    public func project(_ event: V2UserStateEvent) async throws -> UInt64 {
        try await projectResolved(event).sequence
    }

    /// 迁移转发必须保留源用户序号，不在影子分片重新分配。
    public func mirror(_ event: V2UserStateEvent, sequence: UInt64) async throws -> UInt64 {
        guard sequence > 0, sequence <= UInt64(Int64.max) else { throw V2UserStateEventError.invalidEvent }
        return try await project(event, projectionPayloadJSON: event.payloadJSON, allocatedSequence: Int64(sequence)).sequence
    }

    /// The source payload remains the deduplication identity. A retry returns the
    /// first committed projection, even when the caller now resolves different policy.
    func projectResolved(_ event: V2UserStateEvent, projectionPayload: Data? = nil) async throws -> V2UserStateEventProjection {
        let payload: String
        if let projectionPayload {
            payload = try V2UserStateEvent(sourceEventID: event.sourceEventID, userID: event.userID,
                kind: event.kind, payload: projectionPayload, createdAt: event.createdAtTimestamp).payloadJSON
        } else {
            payload = event.payloadJSON
        }
        return try await project(event, projectionPayloadJSON: payload, allocatedSequence: nil)
    }

    func mirrorResolved(_ event: V2UserStateEvent, projection: V2UserStateEventProjection) async throws -> UInt64 {
        guard projection.sequence > 0, projection.sequence <= UInt64(Int64.max) else {
            throw V2UserStateEventError.invalidEvent
        }
        return try await project(event, projectionPayloadJSON: projection.payloadJSON,
            allocatedSequence: Int64(projection.sequence)).sequence
    }

    private func project(_ event: V2UserStateEvent, projectionPayloadJSON: String,
                         allocatedSequence: Int64?) async throws -> V2UserStateEventProjection {
        guard let user = event.userID.uuidValue, let source = event.sourceEventID.uuidValue else {
            throw V2UserStateEventError.invalidEvent
        }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2UserStateEventError.corruptPersistenceState }
            // Serialize with migration fence acquisition, including the first event for a user.
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: table("user_projection_checkpoints")) (user_id, projected_sequence, updated_at)
                VALUES (\(bind: user), 0, clock_timestamp()) ON CONFLICT (user_id) DO NOTHING
                """).run()
            let fence = try await sql.raw("""
                SELECT COALESCE(migration_fence_expires_at > clock_timestamp(), FALSE) AS active
                FROM \(unsafeRaw: table("user_projection_checkpoints"))
                WHERE user_id = \(bind: user) FOR UPDATE
                """).first(decoding: UserStateEventFenceRow.self)
            guard let fence else { throw V2UserStateEventError.corruptPersistenceState }
            guard !fence.active else { throw V2UserShardProjectionTransferError.migrationFenceConflict }
            let inserted = try await sql.raw("""
                INSERT INTO \(unsafeRaw: table("user_state_event_receipts"))
                    (user_id, source_event_id, projection_kind, payload, projection_payload, source_created_at)
                VALUES (\(bind: user), \(bind: source), \(bind: event.kind.rawValue),
                        \(bind: event.payloadJSON)::jsonb, \(bind: projectionPayloadJSON)::jsonb, \(bind: event.createdAtTimestamp))
                ON CONFLICT (user_id, source_event_id, projection_kind) DO NOTHING
                RETURNING user_id
                """).first(decoding: UserStateEventUserRow.self) != nil
            if !inserted {
                guard let prior = try await sql.raw("""
                    SELECT user_sync_sequence AS sequence, projection_payload::text AS projection_payload_json,
                           projection_payload = \(bind: projectionPayloadJSON)::jsonb AS projection_matches,
                           payload = \(bind: event.payloadJSON)::jsonb AS matches
                    FROM \(unsafeRaw: table("user_state_event_receipts"))
                    WHERE user_id = \(bind: user) AND source_event_id = \(bind: source)
                      AND projection_kind = \(bind: event.kind.rawValue)
                    """).first(decoding: UserStateEventReceiptRow.self), let sequence = prior.sequence, sequence > 0
                else { throw V2UserStateEventError.corruptPersistenceState }
                guard prior.matches, allocatedSequence == nil || (allocatedSequence == sequence && prior.projectionMatches) else { throw V2UserStateEventError.identityConflict }
                return V2UserStateEventProjection(sequence: UInt64(sequence), payloadJSON: prior.projectionPayloadJSON)
            }
            let sequence: Int64
            if let allocatedSequence {
                sequence = allocatedSequence
                try await sql.raw("""
                    INSERT INTO \(unsafeRaw: table("user_sync_sequences")) (user_id, next_sequence)
                    VALUES (\(bind: user), \(bind: sequence))
                    ON CONFLICT (user_id) DO UPDATE
                    SET next_sequence = GREATEST(\(unsafeRaw: table("user_sync_sequences")).next_sequence, EXCLUDED.next_sequence)
                    """).run()
            } else {
                guard let row = try await sql.raw("""
                    INSERT INTO \(unsafeRaw: table("user_sync_sequences")) (user_id, next_sequence)
                    VALUES (\(bind: user), 1)
                    ON CONFLICT (user_id) DO UPDATE
                    SET next_sequence = \(unsafeRaw: table("user_sync_sequences")).next_sequence + 1
                    WHERE \(unsafeRaw: table("user_sync_sequences")).next_sequence < \(bind: Int64.max)
                    RETURNING next_sequence AS sequence
                    """).first(decoding: UserStateEventSequenceRow.self), row.sequence > 0
                else { throw V2UserStateEventError.corruptPersistenceState }
                sequence = row.sequence
            }
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: table("user_sync_log"))
                    (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at)
                VALUES (\(bind: user), \(bind: sequence), \(bind: source), \(bind: event.kind.rawValue),
                        \(bind: projectionPayloadJSON)::jsonb, \(bind: event.createdAtTimestamp))
                ON CONFLICT (user_id, user_sync_sequence) DO NOTHING
                """).run()
            guard let occupying = try await sql.raw("""
                SELECT source_event_id = \(bind: source)
                       AND projection_kind = \(bind: event.kind.rawValue)
                       AND payload = \(bind: projectionPayloadJSON)::jsonb AS matches
                FROM \(unsafeRaw: table("user_sync_log"))
                WHERE user_id = \(bind: user) AND user_sync_sequence = \(bind: sequence)
                """).first(decoding: UserStateEventOccupantRow.self), occupying.matches
            else { throw V2UserStateEventError.identityConflict }
            try await sql.raw("""
                UPDATE \(unsafeRaw: table("user_state_event_receipts"))
                SET user_sync_sequence = \(bind: sequence)
                WHERE user_id = \(bind: user) AND source_event_id = \(bind: source)
                  AND projection_kind = \(bind: event.kind.rawValue)
                """).run()
            return V2UserStateEventProjection(sequence: UInt64(sequence), payloadJSON: projectionPayloadJSON)
        }
    }

    private func table(_ name: String) -> String { "\"\(schema)\".\"\(name)\"" }
}

private struct UserStateEventUserRow: Decodable {
    let userID: UUID
    enum CodingKeys: String, CodingKey { case userID = "user_id" }
}
private struct UserStateEventReceiptRow: Decodable {
    let sequence: Int64?
    let matches: Bool
    let projectionPayloadJSON: String
    let projectionMatches: Bool
    enum CodingKeys: String, CodingKey {
        case sequence, matches
        case projectionPayloadJSON = "projection_payload_json"
        case projectionMatches = "projection_matches"
    }
}
private struct UserStateEventSequenceRow: Decodable { let sequence: Int64 }

private struct UserStateEventOccupantRow: Decodable { let matches: Bool }

private struct UserStateEventFenceRow: Decodable { let active: Bool }

/// A committed target result, including the immutable first policy resolution.
struct V2UserStateEventProjection: Sendable {
    let sequence: UInt64
    let payloadJSON: String
}
