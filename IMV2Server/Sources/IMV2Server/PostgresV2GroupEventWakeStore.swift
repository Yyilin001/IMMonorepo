import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 混合大群合并唤醒发件箱的 PostgreSQL 租约存储。
///
/// 该存储不保存用户、设备、消息正文或事件载荷，只保存房间级水位与租约状态。
public struct PostgresV2GroupEventWakeStore: V2GroupEventWakeStore {
    private let database: any Database

    /// 组合数据库。
    ///
    /// - Parameter database: 存放唤醒发件箱与房间水位计数器的数据库。
    public init(database: any Database) { self.database = database }

    /// 认领一批待发布的房间唤醒。
    ///
    /// 认领更新与水位读取刻意拆成两条 `READ COMMITTED` 语句：在租约锁归属本事务之前提交的
    /// 消息事务此时已可见，而仍在追加的消息事务必须先更新被租约占用的发件箱行才能提交，
    /// 因此会覆盖当前修订并保留新的唤醒。若沿用认领语句的原始快照读取房间计数器，
    /// 会在锁等待之后留下一个极窄的水位丢失窗口。
    ///
    /// - Parameters:
    ///   - now: 本次认领时刻。
    ///   - leaseDuration: 租约时长秒数。
    ///   - limit: 本批最多认领的房间数。
    /// - Returns: 本批唤醒租约，水位取发件箱目标与房间当前序号的较大值。
    /// - Throws: 上限非正、租约到期时刻不可编码，或水位、修订、尝试次数非正时抛出
    ///   ``V2GroupEventWakeStoreError/corruptPersistenceState``。
    public func claimPending(now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2GroupEventWakeLease] {
        guard limit > 0,
              let expiry = v2PostgresFutureTimestamp(now: now, interval: leaseDuration)
        else { throw V2GroupEventWakeStoreError.corruptPersistenceState }
        let token = UUID()
        let rows = try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2GroupEventWakeStoreError.corruptPersistenceState
            }
            try await sql.raw("""
                WITH candidates AS (
                    SELECT room_id
                    FROM im_v2.group_event_wake_outbox AS wake
                    WHERE ((state = 'pending' AND next_attempt_at <= \(bind: now))
                       OR (state = 'leased' AND lease_expires_at <= \(bind: now)))
                      AND \(roomWritable(skipLocked: true))
                    ORDER BY next_attempt_at, updated_at
                    LIMIT \(bind: limit)
                    FOR UPDATE OF wake SKIP LOCKED
                )
                UPDATE im_v2.group_event_wake_outbox AS wake
                SET state = 'leased',
                    lease_token = \(bind: token),
                    lease_expires_at = \(bind: expiry),
                    attempt_count = CASE WHEN wake.attempt_count = 2147483647
                        THEN wake.attempt_count ELSE wake.attempt_count + 1 END,
                    updated_at = \(bind: now)
                FROM candidates
                WHERE wake.room_id = candidates.room_id
                """).run()

            // This deliberately is a second READ COMMITTED statement. A
            // message transaction that committed before the lease lock became
            // ours is now visible here. A transaction that is still appending
            // must update the leased outbox row before it can commit, which
            // replaces this revision and preserves another wake. Reading the
            // room counter in the claim UPDATE's original statement snapshot
            // would leave a narrow lost-watermark race after lock waits.
            return try await sql.raw("""
                SELECT wake.room_id,
                       GREATEST(wake.target_room_sequence, room.room_sequence)
                           AS target_room_sequence,
                       wake.revision,
                       wake.attempt_count
                FROM im_v2.group_event_wake_outbox AS wake
                JOIN im_v2.rooms AS room ON room.room_id = wake.room_id
                WHERE wake.lease_token = \(bind: token)
                  AND wake.state = 'leased'
                ORDER BY wake.next_attempt_at, wake.updated_at
                """).all(decoding: GroupEventWakeLeaseRow.self)
        }
        return try rows.map { row in
            guard row.targetRoomSequence > 0, row.revision > 0, row.attemptCount > 0 else {
                throw V2GroupEventWakeStoreError.corruptPersistenceState
            }
            return .init(
                wake: .init(roomID: try .init(row.roomID.uuidString), highWatermark: UInt64(row.targetRoomSequence)),
                revision: UInt64(row.revision),
                claimToken: token,
                attempt: row.attemptCount
            )
        }
    }

    /// 标记唤醒已发布并删除对应发件箱条目。
    ///
    /// 删除带有修订栅栏：若期间已观察到更新的事件并改写了修订或状态，
    /// 本次删除不会命中，新的唤醒得以保留。
    ///
    /// - Parameter lease: 本次唤醒租约。
    /// - Throws: 连接不支持 SQL、房间标识非法或修订超出可编码范围时抛出
    ///   ``V2GroupEventWakeStoreError/corruptPersistenceState``。
    public func markPublished(_ lease: V2GroupEventWakeLease) async throws {
        guard let sql = database as? any SQLDatabase,
              let roomID = UUID(uuidString: lease.wake.roomID.rawValue),
              lease.revision <= UInt64(Int64.max)
        else { throw V2GroupEventWakeStoreError.corruptPersistenceState }
        // Revision fencing is intentional: an UPSERT that observed a newer
        // event changes revision/state before this delete can run.
        try await sql.raw("""
            DELETE FROM im_v2.group_event_wake_outbox AS wake
            WHERE room_id = \(bind: roomID)
              AND lease_token = \(bind: lease.claimToken)
              AND revision = \(bind: Int64(lease.revision))
              AND \(roomWritable(skipLocked: false))
            """).run()
    }

    /// 把租约安排为稍后重试。
    ///
    /// 只有认领令牌与修订都匹配时才会回到待处理状态并写入下次尝试时刻。
    ///
    /// - Parameters:
    ///   - lease: 本次唤醒租约。
    ///   - nextAttemptAt: 下次尝试时刻。
    /// - Throws: 连接不支持 SQL、标识或修订非法、时刻不可编码时抛出
    ///   ``V2GroupEventWakeStoreError/corruptPersistenceState``。
    public func scheduleRetry(_ lease: V2GroupEventWakeLease, nextAttemptAt: Date) async throws {
        guard let sql = database as? any SQLDatabase,
              let roomID = UUID(uuidString: lease.wake.roomID.rawValue),
              lease.revision <= UInt64(Int64.max),
              v2PostgresTimestampCanEncode(nextAttemptAt)
        else { throw V2GroupEventWakeStoreError.corruptPersistenceState }
        try await sql.raw("""
            UPDATE im_v2.group_event_wake_outbox AS wake
            SET state = 'pending',
                lease_token = NULL,
                lease_expires_at = NULL,
                next_attempt_at = \(bind: nextAttemptAt),
                updated_at = \(bind: nextAttemptAt)
            WHERE room_id = \(bind: roomID)
              AND lease_token = \(bind: lease.claimToken)
              AND revision = \(bind: Int64(lease.revision))
              AND \(roomWritable(skipLocked: false))
            """).run()
    }
    // Keep the room lock until the queue mutation commits. Claiming skips
    // busy rooms; terminal/retry callbacks wait and recheck the durable marker.
    private func roomWritable(skipLocked: Bool) -> SQLQueryString {
        """
        (SELECT true FROM im_v2.rooms AS room
         WHERE room.room_id = wake.room_id
         FOR SHARE OF room \(unsafeRaw: skipLocked ? "SKIP LOCKED" : ""))
        """
    }

}

/// 群事件唤醒存储错误。
public enum V2GroupEventWakeStoreError: Error, Equatable, Sendable {
    /// 持久化记录缺失或字段无法解码。
    case corruptPersistenceState
}

private struct GroupEventWakeLeaseRow: Decodable {
    let roomID: UUID
    let targetRoomSequence: Int64
    let revision: Int64
    let attemptCount: Int

    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case targetRoomSequence = "target_room_sequence"
        case revision
        case attemptCount = "attempt_count"
    }
}
