import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 源事务中的定向用户事件待办；载荷独立保存，房间历史裁剪不会破坏待办。
public struct PostgresV2UserStateEventOutbox: V2UserStateEventOutbox {
    private let database: any Database
    private let schema: String

    public init(database: any Database, schema: String = "im_v2") throws {
        guard schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
            throw V2UserStateEventError.invalidEvent
        }
        self.database = database
        self.schema = schema
    }

    /// 必须复用产生用户状态变更的源事务。相同事件的重试不能替换已冻结载荷。
    public func enqueue(_ event: V2UserStateEvent, sourceRoomID: RoomID? = nil, in sql: any SQLDatabase) async throws {
        guard let user = event.userID.uuidValue, let source = event.sourceEventID.uuidValue else {
            throw V2UserStateEventError.invalidEvent
        }
        let room = sourceRoomID?.uuidValue
        guard sourceRoomID == nil || room != nil else { throw V2UserStateEventError.invalidEvent }
        let inserted = try await sql.raw("""
            INSERT INTO \(unsafeRaw: table)
                (source_event_id, user_id, projection_kind, payload, created_at, next_attempt_at, source_room_id)
            VALUES (\(bind: source), \(bind: user), \(bind: event.kind.rawValue),
                    \(bind: event.payloadJSON)::jsonb, \(bind: event.createdAtTimestamp), \(bind: event.createdAtTimestamp), \(bind: room))
            ON CONFLICT (source_event_id, user_id, projection_kind) DO NOTHING
            RETURNING TRUE AS matches
            """).first(decoding: UserStateEventMatchRow.self) != nil
        if !inserted {
            let prior = try await sql.raw("""
                SELECT payload = \(bind: event.payloadJSON)::jsonb AND source_room_id IS NOT DISTINCT FROM \(bind: room)::uuid AS matches
                FROM \(unsafeRaw: table)
                WHERE source_event_id = \(bind: source) AND user_id = \(bind: user)
                  AND projection_kind = \(bind: event.kind.rawValue)
                """).first(decoding: UserStateEventMatchRow.self)
            guard prior?.matches == true else { throw V2UserStateEventError.identityConflict }
        }
    }

    public func claim(now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2UserStateEventLease] {
        let expires = now.addingTimeInterval(leaseDuration)
        guard limit > 0, limit <= 1024, leaseDuration > 0, leaseDuration.isFinite,
              v2PostgresTimestampCanEncode(now), v2PostgresTimestampCanEncode(expires)
        else { throw V2UserStateEventError.invalidEvent }
        guard let sql = database as? any SQLDatabase else { throw V2UserStateEventError.corruptPersistenceState }
        let token = UUID()
        let rows = try await sql.raw("""
            WITH candidates AS (
                SELECT source_event_id, user_id, projection_kind
                FROM \(unsafeRaw: table) AS work
                WHERE ((state = 'pending' AND next_attempt_at <= \(bind: now))
                   OR (state = 'leased' AND lease_until <= \(bind: now)))
                  AND \(sourceRoomWritable(skipLocked: true))
                ORDER BY next_attempt_at, created_at, source_event_id, user_id, projection_kind
                LIMIT \(bind: limit) FOR UPDATE OF work SKIP LOCKED
            )
            UPDATE \(unsafeRaw: table) AS work
            SET state = 'leased', claim_token = \(bind: token), lease_until = \(bind: expires),
                attempt = LEAST(work.attempt::bigint + 1, 2147483647)::integer
            FROM candidates
            WHERE work.source_event_id = candidates.source_event_id
              AND work.user_id = candidates.user_id AND work.projection_kind = candidates.projection_kind
            RETURNING work.source_event_id, work.user_id, work.projection_kind,
                      work.payload::text AS payload_json, work.created_at, work.attempt
            """).all(decoding: UserStateEventClaimRow.self)
        return try rows.map { row in
            guard let kind = V2UserStateEventKind(rawValue: row.projectionKind) else {
                throw V2UserStateEventError.corruptPersistenceState
            }
            return try .init(event: .init(sourceEventID: .init(uuid: row.sourceEventID), userID: .init(uuid: row.userID),
                kind: kind, payload: Data(row.payloadJSON.utf8), createdAt: row.createdAt), token: token, attempt: row.attempt)
        }
    }

    public func acknowledge(_ lease: V2UserStateEventLease, sequence: UInt64, now: Date) async throws -> Bool {
        guard sequence > 0, sequence <= UInt64(Int64.max), v2PostgresTimestampCanEncode(now),
              let sql = database as? any SQLDatabase,
              let source = lease.event.sourceEventID.uuidValue, let user = lease.event.userID.uuidValue
        else { throw V2UserStateEventError.invalidEvent }
        return try await sql.raw("""
            UPDATE \(unsafeRaw: table) AS work
            SET state = 'delivered', user_sync_sequence = \(bind: Int64(sequence)),
                delivered_at = \(bind: now), claim_token = NULL, lease_until = NULL
            WHERE source_event_id = \(bind: source) AND user_id = \(bind: user)
              AND projection_kind = \(bind: lease.event.kind.rawValue)
              AND state = 'leased' AND claim_token = \(bind: lease.token)
              AND lease_until > \(bind: now)
              AND \(sourceRoomWritable(skipLocked: false))
            RETURNING TRUE AS matches
            """).first(decoding: UserStateEventMatchRow.self) != nil
    }

    public func retry(_ lease: V2UserStateEventLease, disposition: V2DurableRetryDisposition) async throws {
        guard let sql = database as? any SQLDatabase,
              let source = lease.event.sourceEventID.uuidValue, let user = lease.event.userID.uuidValue
        else { throw V2UserStateEventError.invalidEvent }
        let state: String
        let next: Date?
        switch disposition {
        case .pause: state = "paused"; next = nil
        case .retry(let at):
            guard v2PostgresTimestampCanEncode(at) else { throw V2UserStateEventError.invalidEvent }
            state = "pending"; next = at
        }
        try await sql.raw("""
            UPDATE \(unsafeRaw: table) AS work
            SET state = \(bind: state), next_attempt_at = COALESCE(\(bind: next), next_attempt_at),
                claim_token = NULL, lease_until = NULL
            WHERE source_event_id = \(bind: source) AND user_id = \(bind: user)
              AND projection_kind = \(bind: lease.event.kind.rawValue)
              AND state = 'leased' AND claim_token = \(bind: lease.token)
              AND \(sourceRoomWritable(skipLocked: false))
            """).run()
    }

    // 修改队列期间锁定明确拥有的房间。即使载荷提及该房间，
    // 控制事件仍保持独立。
    private func sourceRoomWritable(skipLocked: Bool) -> SQLQueryString {
        """
        (work.source_room_id IS NULL OR (
            SELECT true FROM \(unsafeRaw: schema).rooms AS room
            WHERE room.room_id = work.source_room_id
            FOR SHARE OF room \(unsafeRaw: skipLocked ? "SKIP LOCKED" : "")
        ))
        """
    }

    private var table: String { "\"\(schema)\".\"user_state_event_outbox\"" }
}

private struct UserStateEventMatchRow: Decodable { let matches: Bool }
private struct UserStateEventClaimRow: Decodable {
    let sourceEventID: UUID
    let userID: UUID
    let projectionKind: String
    let payloadJSON: String
    let createdAt: V2PostgresTimestamp
    let attempt: Int
    enum CodingKeys: String, CodingKey {
        case sourceEventID = "source_event_id", userID = "user_id", projectionKind = "projection_kind"
        case payloadJSON = "payload_json", createdAt = "created_at", attempt
    }
}
