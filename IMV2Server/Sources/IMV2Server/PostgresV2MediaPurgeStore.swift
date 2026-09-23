import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 媒体清除发件箱的 PostgreSQL 持久化实现。
///
/// 它按租约认领待清除对象，并记录其清除原因与重试进度。
public struct PostgresV2MediaPurgeStore: V2MediaPurgeStore {
    private let database: any Database
    private let makeUUID: @Sendable () -> UUID

    /// 创建清除发件箱存储。
    ///
    /// - Parameters:
    ///   - database: 控制面数据库连接。
    ///   - makeUUID: 认领令牌生成器，默认使用 `UUID.init`。
    public init(database: any Database, makeUUID: @escaping @Sendable () -> UUID = UUID.init) {
        self.database = database
        self.makeUUID = makeUUID
    }

    /// 认领一待清除对象。
    ///
    /// 候选包含待处理项与租约已过期的已认领项；认领使用 `SKIP LOCKED`，
    /// 使多个工作进程可以并行推进。重试计数在饱和时保持原值，避免回绕。
    ///
    /// - Parameters:
    ///   - now: 当前时间。
    ///   - leaseDuration: 本次租约时长，必须为正。
    ///   - limit: 本次最多认领的对象数，必须为正。
    /// - Returns: 已认领的清除租约列表。
    /// - Throws: 时间戳无法表示、原因非法、计数非法或持久化状态损坏时抛出。
    public func claimPending(now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2MediaPurgeLease] {
        guard limit > 0, leaseDuration > 0 else { return [] }
        guard let expiresAt = v2PostgresFutureTimestamp(now: now, interval: leaseDuration) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let token = makeUUID()
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let rows = try await sql.raw("""
                WITH candidates AS (
                    SELECT media_id, reason
                    FROM im_v2.media_purge_outbox
                    WHERE (state = 'pending' AND (next_attempt_at IS NULL OR next_attempt_at <= \(bind: now)))
                       OR (state = 'claimed' AND lease_expires_at <= \(bind: now))
                    ORDER BY created_at, media_id
                    LIMIT \(bind: limit)
                    FOR UPDATE SKIP LOCKED
                )
                UPDATE im_v2.media_purge_outbox AS outbox
                SET state = 'claimed', claim_token = \(bind: token), lease_expires_at = \(bind: expiresAt),
                    next_attempt_at = NULL, paused_at = NULL,
                    retry_count = CASE WHEN outbox.retry_count = 9223372036854775807
                        THEN outbox.retry_count ELSE outbox.retry_count + 1 END
                FROM candidates
                WHERE outbox.media_id = candidates.media_id
                RETURNING outbox.media_id, outbox.reason, outbox.retry_count
                """).all(decoding: MediaPurgeRow.self)
            return try rows.map {
                guard let reason = V2MediaPurgeReason(rawValue: $0.reason) else { throw V2RoomWriteStoreError.corruptPersistenceState }
                guard $0.retryCount > 0, $0.retryCount <= Int64(Int.max) else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                return try .init(
                    mediaID: .init($0.mediaID.uuidString),
                    reason: reason,
                    claimToken: token,
                    attempt: Int($0.retryCount)
                )
            }
        }
    }

    /// 标记本次清除已完成。
    ///
    /// - Parameters:
    ///   - lease: 本次处理持有的清除租约。
    ///   - now: 当前时间。
    /// - Throws: 租约失效或持久化失败时抛出。
    public func markCompleted(_ lease: V2MediaPurgeLease, now: Date) async throws {
        guard v2PostgresTimestampCanEncode(now),
              let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        try await sql.raw("""
            UPDATE im_v2.media_purge_outbox
            SET state = 'completed', completed_at = \(bind: now), claim_token = NULL,
                lease_expires_at = NULL, next_attempt_at = NULL, paused_at = NULL
            WHERE media_id = \(bind: try mediaPurgeUUID(lease.mediaID))
              AND state = 'claimed'
              AND claim_token = \(bind: lease.claimToken)
            """).run()
    }

    /// 按持久重试策略安排下一次清除尝试。
    ///
    /// - Parameters:
    ///   - lease: 本次处理持有的清除租约。
    ///   - disposition: 持久重试处置策略。
    ///   - now: 当前时间。
    /// - Throws: 租约失效或持久化失败时抛出。
    public func scheduleRetry(_ lease: V2MediaPurgeLease, disposition: V2DurableRetryDisposition, now: Date) async throws {
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let mediaID = try mediaPurgeUUID(lease.mediaID)
        switch disposition {
        case .retry(let retryAt):
            guard v2PostgresTimestampCanEncode(retryAt) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            try await sql.raw("""
                UPDATE im_v2.media_purge_outbox
                SET state = 'pending', claim_token = NULL, lease_expires_at = NULL,
                    next_attempt_at = \(bind: retryAt), paused_at = NULL
                WHERE media_id = \(bind: mediaID)
                  AND state = 'claimed' AND claim_token = \(bind: lease.claimToken)
                """).run()
        case .pause:
            guard v2PostgresTimestampCanEncode(now) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            try await sql.raw("""
                UPDATE im_v2.media_purge_outbox
                SET state = 'paused', claim_token = NULL, lease_expires_at = NULL,
                    next_attempt_at = NULL, paused_at = \(bind: now)
                WHERE media_id = \(bind: mediaID)
                  AND state = 'claimed' AND claim_token = \(bind: lease.claimToken)
                """).run()
        }
    }
}

private struct MediaPurgeRow: Decodable {
    let mediaID: UUID
    let reason: String
    let retryCount: Int64
    enum CodingKeys: String, CodingKey {
        case mediaID = "media_id"
        case reason
        case retryCount = "retry_count"
    }
}

private func mediaPurgeUUID(_ identifier: MediaID) throws -> UUID {
    guard let uuid = UUID(uuidString: identifier.rawValue) else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return uuid
}
