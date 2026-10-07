import Foundation
import FluentKit
import SQLKit
import IMV2ServerContracts
import IMV2Core

/// Target-owner durable notifications for every user_sync_log writer. The
/// statement trigger participates in that writer's transaction, so source
/// projection acknowledgment can never erase a target notification window.
public struct PostgresV2UserSyncWakeStore: V2UserSyncWakeStore {
    private let database: any Database
    private let schema: String
    public init(database: any Database, schema: String = "im_v2") throws {
        guard schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
            throw V2RealtimeDirectoryError.invalidInput
        }
        self.database = database; self.schema = schema
    }
    /// Called only after the subscription registration has committed. This is
    /// a fresh primary-owner read, never the pre-registration transaction view.
    public func highWatermark(userID: UserID) async throws -> UInt64 {
        try await highWatermarks(userIDs: [userID])[userID] ?? 0
    }
    /// A post-subscription barrier for one physical owner, including users with
    /// no sequence row. Never N scalar SQL queries or a pre-registration view.
    public func highWatermarks(userIDs: [UserID]) async throws -> [UserID: UInt64] {
        let unique = Array(Set(userIDs))
        guard unique.count <= 128, unique.allSatisfy({ $0.uuidValue != nil }) else { throw V2RealtimeDirectoryError.invalidInput }
        if unique.isEmpty { return [:] }
        let json = String(decoding: try JSONEncoder().encode(unique.map { $0.uuidValue!.uuidString }), as: UTF8.self)
        let rows = try await sql(database).raw("""
            WITH requested AS MATERIALIZED (
                SELECT value::uuid AS user_id FROM jsonb_array_elements_text(\(bind: json)::jsonb)
            )
            SELECT requested.user_id, COALESCE(sequence.next_sequence, 0) AS value
            FROM requested LEFT JOIN \(unsafeRaw: schema).user_sync_sequences sequence USING (user_id)
            """).all(decoding: UserSyncBatchHead.self)
        var result: [UserID: UInt64] = [:]
        for row in rows {
            let user = UserID(uuid: row.userID)
            guard row.value >= 0, result[user] == nil else { throw V2RealtimeDirectoryError.corruptPersistenceState }
            result[user] = UInt64(row.value)
        }
        guard Set(result.keys) == Set(unique) else { throw V2RealtimeDirectoryError.corruptPersistenceState }
        return result
    }
    public func claimPending(now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2UserSyncWakeLease] {
        guard limit > 0, limit <= 4096, let expiry = v2PostgresFutureTimestamp(now: now, interval: leaseDuration) else {
            throw V2RealtimeDirectoryError.invalidInput
        }
        let token = UUID()
        let rows = try await database.transaction { db in
            let sql = try sql(db)
            // Writers lock the sequence before inserting their log and touching
            // wake rows. Claimers use exactly that lock order and skip busy users.
            try await sql.raw("""
                WITH candidates AS (
                    SELECT wake.user_id FROM \(unsafeRaw: schema).user_sync_wake_outbox wake
                    WHERE ((wake.state = 'pending' AND wake.next_attempt_at <= \(bind: now))
                       OR (wake.state = 'leased' AND wake.lease_expires_at <= \(bind: now)))
                    AND (SELECT true FROM \(unsafeRaw: schema).user_sync_sequences sequence
                         WHERE sequence.user_id = wake.user_id FOR SHARE OF sequence SKIP LOCKED)
                    ORDER BY wake.next_attempt_at, wake.updated_at
                    LIMIT \(bind: limit) FOR UPDATE OF wake SKIP LOCKED
                )
                UPDATE \(unsafeRaw: schema).user_sync_wake_outbox wake
                SET state = 'leased', lease_token = \(bind: token), lease_expires_at = \(bind: expiry),
                    attempt_count = LEAST(wake.attempt_count::bigint + 1, 2147483647)::integer,
                    updated_at = \(bind: now)
                FROM candidates WHERE wake.user_id = candidates.user_id
                """).run()
            // A separate READ COMMITTED statement sees commits which preceded
            // our acquisition of the wake row. A later writer must supersede
            // the leased revision before its own transaction can commit.
            return try await sql.raw("""
                SELECT wake.user_id, GREATEST(wake.target_user_sequence, sequence.next_sequence) AS target_user_sequence,
                       wake.revision, wake.attempt_count
                FROM \(unsafeRaw: schema).user_sync_wake_outbox wake
                JOIN \(unsafeRaw: schema).user_sync_sequences sequence USING (user_id)
                WHERE wake.state = 'leased' AND wake.lease_token = \(bind: token)
                ORDER BY wake.next_attempt_at, wake.updated_at
                """).all(decoding: UserWakeRow.self)
        }
        return try rows.map { row in
            guard row.target > 0, row.revision > 0, row.attempt > 0 else { throw V2RealtimeDirectoryError.corruptPersistenceState }
            return .init(wake: .init(userID: row.userID.uuidString.lowercased(), highWatermark: UInt64(row.target)),
                         revision: row.revision, claimToken: token, attempt: row.attempt)
        }
    }
    public func markPublished(_ lease: V2UserSyncWakeLease) async throws {
        guard let user = UUID(uuidString: lease.wake.userID), lease.revision > 0 else { throw V2RealtimeDirectoryError.invalidInput }
        try await sql(database).raw("""
            DELETE FROM \(unsafeRaw: schema).user_sync_wake_outbox
            WHERE user_id = \(bind: user) AND state = 'leased'
              AND lease_token = \(bind: lease.claimToken) AND revision = \(bind: lease.revision)
            """).run()
    }
    public func scheduleRetry(_ lease: V2UserSyncWakeLease, nextAttemptAt: Date) async throws {
        guard let user = UUID(uuidString: lease.wake.userID), lease.revision > 0,
              v2PostgresTimestampCanEncode(nextAttemptAt) else { throw V2RealtimeDirectoryError.invalidInput }
        try await sql(database).raw("""
            UPDATE \(unsafeRaw: schema).user_sync_wake_outbox
            SET state = 'pending', lease_token = NULL, lease_expires_at = NULL,
                next_attempt_at = \(bind: nextAttemptAt), updated_at = \(bind: nextAttemptAt)
            WHERE user_id = \(bind: user) AND state = 'leased'
              AND lease_token = \(bind: lease.claimToken) AND revision = \(bind: lease.revision)
            """).run()
    }
    private func sql(_ database: any Database) throws -> any SQLDatabase {
        guard let sql = database as? any SQLDatabase else { throw V2RealtimeDirectoryError.corruptPersistenceState }; return sql
    }
}
private struct UserWakeRow: Decodable {
    let userID: UUID; let target: Int64; let revision: Int64; let attempt: Int
    enum CodingKeys: String, CodingKey { case userID = "user_id", target = "target_user_sequence", revision, attempt = "attempt_count" }
}

private struct UserSyncBatchHead: Decodable {
    let userID: UUID; let value: Int64
    enum CodingKeys: String, CodingKey { case userID = "user_id", value }
}
