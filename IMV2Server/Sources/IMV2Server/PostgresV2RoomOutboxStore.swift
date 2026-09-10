import Fluent
import Foundation
import IMV2Core
import SQLKit

/// 持久化、至少执行一次的发件箱实现。
///
/// 租约令牌用于栅栏掉陈旧工作器，避免它把更新的认领标记为已发布或已释放。
public struct PostgresV2RoomOutboxStore: V2BatchRoomOutboxStore {
    private let database: any Database
    private let makeUUID: @Sendable () -> UUID

    /// 组合数据库与认领令牌生成方式。
    ///
    /// - Parameters:
    ///   - database: 存放房间发件箱的数据库。
    ///   - makeUUID: 认领令牌生成方式。
    public init(database: any Database, makeUUID: @escaping @Sendable () -> UUID = UUID.init) {
        self.database = database
        self.makeUUID = makeUUID
    }

    /// 认领一批待发布的发件箱条目。
    ///
    /// 候选需处于待处理状态、已到或未设置下次尝试时间、且旧租约已过期；
    /// 候选行按创建时间排序并使用 `FOR UPDATE SKIP LOCKED` 选取，重试计数在事务内自增且不会溢出。
    ///
    /// - Parameters:
    ///   - now: 本次认领时刻。
    ///   - leaseDuration: 租约时长秒数，非正时返回空结果。
    ///   - limit: 本批最多认领的数量，非正时返回空结果。
    /// - Returns: 本批租约。
    /// - Throws: 租约到期时刻不可编码或连接不支持 SQL 时抛出
    ///   ``V2RoomWriteStoreError/corruptPersistenceState``。
    public func claimPending(now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2OutboxLease] {
        guard limit > 0, leaseDuration > 0 else { return [] }
        guard let expiry = v2PostgresFutureTimestamp(now: now, interval: leaseDuration) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let token = makeUUID()
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let rows = try await sql.raw("""
                WITH candidates AS (
                    SELECT source_event_id, plan_id
                    FROM im_v2.room_outbox
                    WHERE state = 'pending'
                      AND (next_attempt_at IS NULL OR next_attempt_at <= \(bind: now))
                      AND (lease_expires_at IS NULL OR lease_expires_at <= \(bind: now))
                    ORDER BY created_at, source_event_id
                    LIMIT \(bind: limit)
                    FOR UPDATE SKIP LOCKED
                )
                UPDATE im_v2.room_outbox AS outbox
                SET claim_token = \(bind: token),
                    lease_expires_at = \(bind: expiry),
                    retry_count = CASE WHEN outbox.retry_count = 9223372036854775807 THEN outbox.retry_count ELSE outbox.retry_count + 1 END
                FROM candidates
                WHERE outbox.source_event_id = candidates.source_event_id
                RETURNING outbox.source_event_id, outbox.plan_id, outbox.retry_count
                """).all(decoding: OutboxRow.self)
            return try rows.map { row in
                .init(
                    trigger: .init(
                        sourceEventID: try EventID(row.sourceEventID.uuidString),
                        planID: try FanoutPlanID(row.planID.uuidString)
                    ),
                    claimToken: token,
                    attempt: try retryAttempt(row.retryCount)
                )
            }
        }
    }

    /// 标记单条租约已发布。
    ///
    /// - Parameter lease: 本次租约。
    /// - Throws: 连接不支持 SQL 时抛出 ``V2RoomWriteStoreError/corruptPersistenceState``。
    public func markPublished(_ lease: V2OutboxLease) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let eventID = try eventUUID(lease.trigger.sourceEventID)
        try await sql.raw("""
            UPDATE im_v2.room_outbox
            SET state = 'published', claim_token = NULL, lease_expires_at = NULL,
                next_attempt_at = NULL, paused_at = NULL, last_failure_code = NULL
            WHERE source_event_id = \(bind: eventID)
              AND state = 'pending'
              AND claim_token = \(bind: lease.claimToken)
            """).run()
    }

    /// 以集合语句批量标记发布。
    ///
    /// 只需要一次往返即可完成整批终结；租约令牌仍然逐条匹配，因此被取代的陈旧认领不会被误标记。
    ///
    /// - Parameter leases: 本批租约。
    /// - Throws: 连接不支持 SQL 时抛出 ``V2RoomWriteStoreError/corruptPersistenceState``。
    public func markPublished(_ leases: [V2OutboxLease]) async throws {
        guard !leases.isEmpty else { return }
        let input = try leases.map {
            OutboxPublishInput(
                sourceEventID: try eventUUID($0.trigger.sourceEventID),
                claimToken: $0.claimToken
            )
        }
        guard Set(input.map(\.sourceEventID)).count == input.count else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let inputJSON = try outboxJSON(input)
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard let mutation = try await sql.raw("""
                WITH input AS MATERIALIZED (
                    SELECT source_event_id, claim_token
                    FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb)
                        AS value(source_event_id uuid, claim_token uuid)
                ), published AS (
                    UPDATE im_v2.room_outbox AS outbox
                    SET state = 'published', claim_token = NULL,
                        lease_expires_at = NULL, next_attempt_at = NULL,
                        paused_at = NULL, last_failure_code = NULL
                    FROM input
                    WHERE outbox.source_event_id = input.source_event_id
                      AND outbox.state = 'pending'
                      AND outbox.claim_token = input.claim_token
                    RETURNING outbox.source_event_id
                ), already_terminal AS MATERIALIZED (
                    -- Zero-audience settlement (or a completed delivery race)
                    -- can finish the source before relay acknowledgement.
                    -- Accept only durable terminal evidence; pending rows
                    -- still require the exact current claim token above.
                    SELECT outbox.source_event_id
                    FROM input
                    JOIN im_v2.room_outbox AS outbox USING (source_event_id)
                    JOIN im_v2.fanout_plans AS plan
                      ON plan.source_event_id = outbox.source_event_id
                     AND plan.plan_id = outbox.plan_id
                    WHERE outbox.state = 'terminal' AND plan.state = 'terminal'
                )
                SELECT (SELECT COUNT(*)::bigint FROM input) AS input_count,
                       (SELECT COUNT(*)::bigint FROM published)
                         + (SELECT COUNT(*)::bigint FROM already_terminal) AS published_count
                """).first(decoding: OutboxBatchPublishMutationRow.self),
                  mutation.inputCount == Int64(leases.count),
                  mutation.publishedCount == Int64(leases.count)
            else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
        }
    }

    /// 立即释放租约以便重试。
    ///
    /// - Parameter lease: 本次租约。
    /// - Throws: 连接不支持 SQL 时抛出 ``V2RoomWriteStoreError/corruptPersistenceState``。
    public func release(_ lease: V2OutboxLease) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let eventID = try eventUUID(lease.trigger.sourceEventID)
        try await sql.raw("""
            UPDATE im_v2.room_outbox
            SET claim_token = NULL, lease_expires_at = NULL, next_attempt_at = NULL
            WHERE source_event_id = \(bind: eventID)
              AND state = 'pending'
              AND claim_token = \(bind: lease.claimToken)
        """).run()
    }

    /// 按处置结果安排重试或暂停。
    ///
    /// 重试处置写入下次尝试时刻，暂停处置清空它；两者都会清空认领令牌与租约。
    ///
    /// - Parameters:
    ///   - lease: 本次租约。
    ///   - disposition: 下一步处置。
    ///   - now: 记录时刻。
    /// - Throws: 时刻不可编码或连接不支持 SQL 时抛出
    ///   ``V2RoomWriteStoreError/corruptPersistenceState``。
    public func scheduleRetry(_ lease: V2OutboxLease, disposition: V2DurableRetryDisposition, now: Date) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let eventID = try eventUUID(lease.trigger.sourceEventID)
        switch disposition {
        case .retry(let retryAt):
            guard v2PostgresTimestampCanEncode(retryAt) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            try await sql.raw("""
                UPDATE im_v2.room_outbox
                SET claim_token = NULL, lease_expires_at = NULL,
                    next_attempt_at = \(bind: retryAt), paused_at = NULL,
                    last_failure_code = 'worker_failure'
                WHERE source_event_id = \(bind: eventID)
                  AND state = 'pending' AND claim_token = \(bind: lease.claimToken)
                """).run()
        case .pause:
            guard v2PostgresTimestampCanEncode(now) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            try await sql.raw("""
                UPDATE im_v2.room_outbox
                SET state = 'paused', claim_token = NULL, lease_expires_at = NULL,
                    next_attempt_at = NULL, paused_at = \(bind: now),
                    last_failure_code = 'retry_exhausted'
                WHERE source_event_id = \(bind: eventID)
                  AND state = 'pending' AND claim_token = \(bind: lease.claimToken)
                """).run()
        }
    }

    /// 把因该来源事件暂停的条目重新放回待处理状态。
    ///
    /// 运维重放是显式操作：它绝不伪造终态结果，也不改动来源事件，
    /// 只是把暂停的工作交还给正常租约流程。
    ///
    /// 供运维重放使用，会清空失败码与暂停时间，使该事件可以按正常节奏重新投递。
    ///
    /// - Parameter sourceEventID: 来源事件标识。
    /// - Throws: 连接不支持 SQL 时抛出 ``V2RoomWriteStoreError/corruptPersistenceState``。
    public func requeuePaused(sourceEventID: EventID) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        try await sql.raw("""
            UPDATE im_v2.room_outbox
            SET state = 'pending', claim_token = NULL, lease_expires_at = NULL,
                next_attempt_at = NULL, paused_at = NULL, last_failure_code = NULL,
                retry_count = 0
            WHERE source_event_id = \(bind: try eventUUID(sourceEventID))
              AND state = 'paused'
            """).run()
    }
}

private struct OutboxRow: Decodable {
    let sourceEventID: UUID
    let planID: UUID
    let retryCount: Int64
    enum CodingKeys: String, CodingKey { case sourceEventID = "source_event_id", planID = "plan_id", retryCount = "retry_count" }
}

private struct OutboxPublishInput: Encodable {
    let sourceEventID: UUID
    let claimToken: UUID
    enum CodingKeys: String, CodingKey {
        case sourceEventID = "source_event_id"
        case claimToken = "claim_token"
    }
}

private struct OutboxBatchPublishMutationRow: Decodable {
    let inputCount: Int64
    let publishedCount: Int64
    enum CodingKeys: String, CodingKey {
        case inputCount = "input_count"
        case publishedCount = "published_count"
    }
}

private func retryAttempt(_ value: Int64) throws -> Int {
    guard value > 0, value <= Int64(Int.max) else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return Int(value)
}

private func eventUUID(_ identifier: EventID) throws -> UUID {
    guard let value = UUID(uuidString: identifier.rawValue) else {
        throw V2RoomWriteStoreError.corruptPersistenceState
    }
    return value
}


private func outboxJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    guard let json = String(data: try encoder.encode(value), encoding: .utf8) else {
        throw V2RoomWriteStoreError.corruptPersistenceState
    }
    return json
}
