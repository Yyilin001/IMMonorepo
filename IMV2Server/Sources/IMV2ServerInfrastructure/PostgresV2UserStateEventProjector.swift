import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
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

    /// 来源载荷始终用作去重身份。重试会返回首次提交的投影，
    /// 即使调用方此时解析出不同的策略也一样。
    func projectResolved(_ event: V2UserStateEvent, projectionPayload: Data? = nil, notification: V2RoomDispatchLease? = nil) async throws -> V2UserStateEventProjection {
        let payload: String
        if let projectionPayload {
            payload = try V2UserStateEvent(sourceEventID: event.sourceEventID, userID: event.userID,
                kind: event.kind, payload: projectionPayload, createdAt: event.createdAtTimestamp).payloadJSON
        } else {
            payload = event.payloadJSON
        }
        return try await project(event, projectionPayloadJSON: payload, notification: notification)
    }

    private func project(_ event: V2UserStateEvent, projectionPayloadJSON: String, notification: V2RoomDispatchLease?) async throws -> V2UserStateEventProjection {
        guard let user = event.userID.uuidValue, let source = event.sourceEventID.uuidValue else {
            throw V2UserStateEventError.invalidEvent
        }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2UserStateEventError.corruptPersistenceState }
            // 对每个用户的回执分配串行化，包括其首个事件。
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: table("user_projection_checkpoints")) (user_id, projected_sequence, updated_at)
                VALUES (\(bind: user), 0, clock_timestamp()) ON CONFLICT (user_id) DO NOTHING
                """).run()
            let checkpoint = try await sql.raw("""
                SELECT user_id
                FROM \(unsafeRaw: table("user_projection_checkpoints"))
                WHERE user_id = \(bind: user) FOR UPDATE
                """).first(decoding: UserStateEventUserRow.self)
            guard checkpoint != nil else { throw V2UserStateEventError.corruptPersistenceState }
            if event.kind == .roomHead {
                return try await projectAccountRoomHeadUnderLock(event, user: user, source: source,
                    projectionPayloadJSON: projectionPayloadJSON, notification: notification, sql: sql)
            }
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
                           payload = \(bind: event.payloadJSON)::jsonb AS matches
                    FROM \(unsafeRaw: table("user_state_event_receipts"))
                    WHERE user_id = \(bind: user) AND source_event_id = \(bind: source)
                      AND projection_kind = \(bind: event.kind.rawValue)
                    """).first(decoding: UserStateEventReceiptRow.self), let sequence = prior.sequence, sequence > 0
                else { throw V2UserStateEventError.corruptPersistenceState }
                guard prior.matches else { throw V2UserStateEventError.identityConflict }
                return V2UserStateEventProjection(sequence: UInt64(sequence), payloadJSON: prior.projectionPayloadJSON)
            }
            let sequence: Int64
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

    /// One durable account transaction amortizes commits across independently
    /// accepted room changes. The original room acceptance transactions and
    /// sequences remain separate; each source event keeps its own receipt/alert.
    package func projectRoomChanges(_ leases: [V2RoomDispatchLease], to userID: UserID) async throws {
        guard (1...32).contains(leases.count), let user = userID.uuidValue else { throw V2UserStateEventError.invalidEvent }
        let events = try leases.map { try v2AccountRoomChangeEvent($0, userID: userID) }
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2UserStateEventError.corruptPersistenceState }
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: table("user_projection_checkpoints")) (user_id, projected_sequence, updated_at)
                VALUES (\(bind: user), 0, clock_timestamp()) ON CONFLICT (user_id) DO NOTHING
                """).run()
            guard try await sql.raw("SELECT user_id FROM \(unsafeRaw: table("user_projection_checkpoints")) WHERE user_id = \(bind: user) FOR UPDATE")
                .first() != nil else { throw V2UserStateEventError.corruptPersistenceState }
            for (event, lease) in zip(events, leases) {
                try Task.checkCancellation()
                _ = try await projectAccountRoomHeadUnderLock(event, user: user, source: lease.eventID,
                    projectionPayloadJSON: event.payloadJSON, notification: lease.messageID == nil ? nil : lease, sql: sql)
            }
        }
    }

    /// The checkpoint row is already locked by the caller's transaction. Allocate
    /// the account sequence and persist all effects in one statement; this does
    /// not batch room writes or acknowledge before the target transaction commits.
    private func projectAccountRoomHeadUnderLock(_ event: V2UserStateEvent, user: UUID, source: UUID,
        projectionPayloadJSON: String, notification: V2RoomDispatchLease?, sql: any SQLDatabase
    ) async throws -> V2UserStateEventProjection {
        if let prior = try await sql.raw("""
            SELECT user_sync_sequence AS sequence, projection_payload::text AS projection_payload_json,
                   payload = \(bind: event.payloadJSON)::jsonb AS matches
            FROM \(unsafeRaw: table("user_state_event_receipts"))
            WHERE user_id = \(bind: user) AND source_event_id = \(bind: source)
              AND projection_kind = \(bind: event.kind.rawValue)
            """).first(decoding: UserStateEventReceiptRow.self) {
            guard prior.matches else { throw V2UserStateEventError.identityConflict }
            guard let sequence = prior.sequence, sequence > 0 else { throw V2UserStateEventError.corruptPersistenceState }
            return .init(sequence: UInt64(sequence), payloadJSON: prior.projectionPayloadJSON)
        }
        var statement: SQLQueryString = """
            WITH allocated AS (
                INSERT INTO \(unsafeRaw: table("user_sync_sequences")) (user_id, next_sequence)
                VALUES (\(bind: user), 1)
                ON CONFLICT (user_id) DO UPDATE
                SET next_sequence = \(unsafeRaw: table("user_sync_sequences")).next_sequence + 1
                WHERE \(unsafeRaw: table("user_sync_sequences")).next_sequence < \(bind: Int64.max)
                RETURNING next_sequence
            ), receipt AS (
                INSERT INTO \(unsafeRaw: table("user_state_event_receipts"))
                    (user_id, source_event_id, projection_kind, payload, projection_payload,
                     source_created_at, user_sync_sequence)
                SELECT \(bind: user), \(bind: source), \(bind: event.kind.rawValue),
                       \(bind: event.payloadJSON)::jsonb, \(bind: projectionPayloadJSON)::jsonb,
                       \(bind: event.createdAtTimestamp), next_sequence FROM allocated
                RETURNING user_id, source_event_id, projection_kind, projection_payload, user_sync_sequence
            ), logged AS (
                INSERT INTO \(unsafeRaw: table("user_sync_log"))
                    (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at)
                SELECT user_id, user_sync_sequence, source_event_id, projection_kind, projection_payload,
                       \(bind: event.createdAtTimestamp) FROM receipt
                RETURNING user_id, user_sync_sequence
            )
            """
        if let notification, notification.senderID != event.userID {
            guard notification.eventID == source, let message = notification.messageID,
                  let room = notification.roomID.uuidValue, let sender = notification.senderID?.uuidValue,
                  let head = Int64(exactly: notification.roomSequence),
                  let revision = Int64(exactly: notification.membershipRevision) else {
                throw V2UserStateEventError.invalidEvent
            }
            statement += """
                , notified AS (
                    INSERT INTO \(unsafeRaw: table("account_notification_outbox"))
                        (user_id, source_event_id, message_id, room_id, room_sequence,
                         membership_revision, sender_user_id, is_mention, created_at, next_attempt_at)
                    SELECT user_id, \(bind: source), \(bind: message), \(bind: room),
                           \(bind: head), \(bind: revision), \(bind: sender),
                           \(bind: notification.mentionsEveryone || notification.mentionedUserIDs.contains(event.userID)),
                           \(bind: notification.createdAtTimestamp), \(bind: notification.createdAtTimestamp)
                    FROM logged
                    RETURNING user_id
                )
                """
        }
        statement += " SELECT user_sync_sequence AS sequence FROM logged"
        guard let result = try await sql.raw(statement).first(decoding: UserStateEventSequenceRow.self), result.sequence > 0 else {
            throw V2UserStateEventError.corruptPersistenceState
        }
        return .init(sequence: UInt64(result.sequence), payloadJSON: projectionPayloadJSON)
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
    enum CodingKeys: String, CodingKey {
        case sequence, matches
        case projectionPayloadJSON = "projection_payload_json"
    }
}
private struct UserStateEventSequenceRow: Decodable { let sequence: Int64 }

private struct UserStateEventOccupantRow: Decodable { let matches: Bool }


/// 已提交的目标结果，包含不可变的首次策略解析结果。
struct V2UserStateEventProjection: Sendable {
    let sequence: UInt64
    let payloadJSON: String
}
