import IMV2ServerApplication
import IMV2ServerContracts
import Crypto
import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 范围受限的运维重放动作的 PostgreSQL 实现。
///
/// 审计写入、暂停状态跃迁与幂等结果属于同一个事务：进程崩溃后要么没有审计记录，
/// 要么留下完整可重放的结果，绝不会出现含义不明的管理动作。
public struct PostgresV2DurableWorkReplayStore: V2DurableWorkReplayStore {
    private let database: any Database

    /// 组合数据库。
    ///
    /// - Parameter database: 存放各工作状态表与重放审计的数据库。
    public init(database: any Database) {
        self.database = database
    }

    /// 执行一次运维重放。
    ///
    /// 同一操作标识已有审计记录时，校验其目标与本次完全一致并返回原结论；
    /// 否则先以唯一约束抢占该操作标识，再按目标类型把对应工作恢复为待处理，最后回填审计结论。
    /// 目标当前不在暂停状态时会记录「未暂停」结论，作为可重放的审计证据而非错误。
    ///
    /// - Parameters:
    ///   - command: 重放命令。
    ///   - operatorPrincipal: 已认证的运维主体标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 重放结果。
    /// - Throws: 标识非法、时刻不可编码或连接不支持 SQL 时抛出
    ///   ``V2DurableWorkReplayStoreError/corruptPersistenceState``；
    ///   同一操作标识的目标不一致时抛出
    ///   ``V2DurableWorkReplayStoreError/idempotencyConflict``。
    public func replay(
        _ command: V2DurableWorkReplayCommand,
        operatorPrincipal: String,
        now: Date
    ) async throws -> V2DurableWorkReplayResult {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2DurableWorkReplayStoreError.corruptPersistenceState
            }
            return try await v2ReplayDurableWork(command, operatorPrincipal: operatorPrincipal, now: now, sql: sql)
        }
    }

    /// 在调用方事务内执行一次单目标重放。
    ///
    /// 单目标与批量共用同一段代码：批量只会为每个精确目标派生一个稳定的行级操作标识，
    /// 然后逐个走这条路径，因此审计形状、幂等语义与"不会把工作标成终态"的约束完全一致。
    private func v2ReplayDurableWork(
        _ command: V2DurableWorkReplayCommand,
        operatorPrincipal: String,
        now: Date,
        sql: any SQLDatabase
    ) async throws -> V2DurableWorkReplayResult {
        let sourceEventID = try replayUUID(command.target.sourceEventID)
        let targetUserID = try command.target.targetUserID.map(replayUUID)
        do {

            func priorResult() async throws -> V2DurableWorkReplayResult? {
                guard let prior = try await sql.raw("""
                    SELECT operation_id, target_kind, source_event_id, target_user_id,
                           projection_kind, reason_code, outcome
                    FROM im_v2.durable_work_replay_audit
                    WHERE operation_id = \(bind: command.operationID)
                    FOR UPDATE
                    """).first(decoding: DurableWorkReplayAuditRow.self)
                else { return nil }
                guard prior.matches(command, sourceEventID: sourceEventID, targetUserID: targetUserID),
                      let outcome = V2DurableWorkReplayOutcome(rawValue: prior.outcome)
                else { throw V2DurableWorkReplayStoreError.idempotencyConflict }
                return .init(operationID: command.operationID, outcome: outcome, wasIdempotent: true)
            }
            if let prior = try await priorResult() { return prior }
            guard v2PostgresTimestampCanEncode(now) else { throw V2DurableWorkReplayStoreError.corruptPersistenceState }

            let inserted = try await sql.raw("""
                INSERT INTO im_v2.durable_work_replay_audit
                    (operation_id, operator_principal, target_kind, source_event_id,
                     target_user_id, projection_kind, reason_code, requested_at, outcome)
                VALUES
                    (\(bind: command.operationID), \(bind: operatorPrincipal), \(bind: command.target.kind.rawValue), \(bind: sourceEventID),
                     \(bind: targetUserID), \(bind: command.target.projectionKind), \(bind: command.reason.rawValue), \(bind: now), 'processing')
                ON CONFLICT (operation_id) DO NOTHING
                RETURNING operation_id
                """).first(decoding: ReplayInsertRow.self) != nil

            if !inserted {
                guard let prior = try await priorResult() else { throw V2DurableWorkReplayStoreError.corruptPersistenceState }
                return prior
            }

            let didRequeue: Bool
            switch command.target.kind {
            case .userStateEvent:
                guard let targetUserID, let projectionKind = command.target.projectionKind else {
                    throw V2DurableWorkReplayStoreError.corruptPersistenceState
                }
                // 来源归属不可变；修改事件前先锁定房间。
                // 栅栏检查失败时也会回滚审计预留。
                guard let source = try await sql.raw("""
                    SELECT source_room_id
                    FROM im_v2.user_state_event_outbox
                    WHERE source_event_id = \(bind: sourceEventID)
                      AND user_id = \(bind: targetUserID) AND projection_kind = \(bind: projectionKind)
                    """).first(decoding: ReplayUserEventSourceRow.self) else {
                    didRequeue = false
                    break
                }
                if let roomID = source.sourceRoomID {
                    guard try await sql.raw("""
                        SELECT room_id FROM im_v2.rooms
                        WHERE room_id = \(bind: roomID) FOR SHARE
                        """).first(decoding: ReplayContentReviewRoomRow.self) != nil else { throw V2RoomOwnerFenceError.ownerChanged }
                }
                didRequeue = try await sql.raw("""
                    UPDATE im_v2.user_state_event_outbox
                    SET state = 'pending', claim_token = NULL, lease_until = NULL,
                        next_attempt_at = \(bind: now), attempt = 0
                    WHERE source_event_id = \(bind: sourceEventID)
                      AND user_id = \(bind: targetUserID)
                      AND projection_kind = \(bind: projectionKind)
                      AND source_room_id IS NOT DISTINCT FROM \(bind: source.sourceRoomID)::uuid
                      AND state = 'paused'
                    RETURNING source_event_id
                    """).first(decoding: ReplayTargetRow.self) != nil
            case .contentReview:
                // 与审核工作器一样，在处理任务前先锁定房间。
                // 外层事务也会回滚审计预留。
                guard try await sql.raw("""
                    SELECT room.room_id
                    FROM im_v2.rooms AS room
                    JOIN im_v2.content_review_jobs AS job ON job.room_id = room.room_id
                    WHERE job.message_id = \(bind: sourceEventID)
                    FOR SHARE OF room
                    """).first(decoding: ReplayContentReviewRoomRow.self) != nil else {
                    didRequeue = false
                    break
                }
                didRequeue = try await sql.raw("""
                    UPDATE im_v2.content_review_jobs
                    SET state = 'pending', claim_token = NULL, lease_expires_at = NULL,
                        next_attempt_at = NULL, paused_at = NULL, retry_count = 0
                    WHERE message_id = \(bind: sourceEventID)
                      AND state = 'paused'
                    RETURNING message_id AS source_event_id
                    """).first(decoding: ReplayTargetRow.self) != nil
            case .mediaScan:
                didRequeue = try await sql.raw("""
                    UPDATE im_v2.media_scan_outbox
                    SET state = 'pending', claim_token = NULL, lease_expires_at = NULL,
                        next_attempt_at = NULL, paused_at = NULL, retry_count = 0
                    WHERE media_id = \(bind: sourceEventID)
                      AND state = 'paused'
                    RETURNING media_id AS source_event_id
                    """).first(decoding: ReplayTargetRow.self) != nil
            case .mediaPurge:
                didRequeue = try await sql.raw("""
                    UPDATE im_v2.media_purge_outbox
                    SET state = 'pending', claim_token = NULL, lease_expires_at = NULL,
                        next_attempt_at = NULL, paused_at = NULL, retry_count = 0
                    WHERE media_id = \(bind: sourceEventID)
                      AND state = 'paused'
                    RETURNING media_id AS source_event_id
                    """).first(decoding: ReplayTargetRow.self) != nil
            case .readReceiptPreferencePropagation:
                guard let targetUserID else {
                    throw V2DurableWorkReplayStoreError.corruptPersistenceState
                }
                didRequeue = try await sql.raw("""
                    UPDATE im_v2.read_receipt_preference_propagation_outbox
                    SET state = 'pending', claim_token = NULL, lease_expires_at = NULL,
                        next_attempt_at = NULL, paused_at = NULL, last_failure_code = NULL,
                        retry_count = 0
                    WHERE actor_user_id = \(bind: targetUserID)
                      AND operation_id = \(bind: sourceEventID)
                      AND state = 'paused'
                    RETURNING operation_id AS source_event_id
                    """).first(decoding: ReplayTargetRow.self) != nil
            case .userProjection:
                guard let targetUserID else {
                    throw V2DurableWorkReplayStoreError.corruptPersistenceState
                }
                didRequeue = try await sql.raw("""
                    WITH requeued AS (
                        UPDATE im_v2.user_projection_checkpoints AS checkpoint
                        SET state = 'ready', failure_count = 0, failed_sequence = NULL,
                            next_attempt_at = NULL, last_failure_code = NULL,
                            paused_at = NULL, updated_at = \(bind: now)
                        WHERE checkpoint.user_id = \(bind: targetUserID)
                          AND checkpoint.state = 'paused'
                          AND EXISTS (
                              SELECT 1
                              FROM im_v2.user_sync_log AS log
                              WHERE log.user_id = checkpoint.user_id
                                AND log.user_sync_sequence = checkpoint.failed_sequence
                                AND log.source_event_id = \(bind: sourceEventID)
                          )
                        RETURNING checkpoint.user_id
                    )
                    INSERT INTO im_v2.user_projection_ready
                        (user_id, available_at, enqueued_at, updated_at)
                    SELECT user_id, \(bind: now), \(bind: now), \(bind: now)
                    FROM requeued
                    ON CONFLICT (user_id) DO UPDATE
                    SET available_at = EXCLUDED.available_at,
                        updated_at = EXCLUDED.updated_at
                    RETURNING \(bind: sourceEventID) AS source_event_id
                    """).first(decoding: ReplayTargetRow.self) != nil
            }
            let outcome: V2DurableWorkReplayOutcome = didRequeue ? .requeued : .notPaused
            try await sql.raw("""
                UPDATE im_v2.durable_work_replay_audit
                SET outcome = \(bind: outcome.rawValue)
                WHERE operation_id = \(bind: command.operationID)
                  AND outcome = 'processing'
                """).run()
            return .init(operationID: command.operationID, outcome: outcome, wasIdempotent: false)
        }
    }

    /// 按来源事件批量重放该事件下的暂停行。
    ///
    /// 选择面是精确的：只有这一个事件，没有扫描或自由筛选；行级审计由
    /// `v2BatchReplayOperationID` 从批量标识稳定派生，因此重复调用不会重复重放。
    ///
    /// - Parameters:
    ///   - command: 批量重放命令。
    ///   - operatorPrincipal: 已认证的运维主体标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 本次批量重放结论。
    /// - Throws: 类型不支持批量、行数越界或持久化失败时抛出。
    public func replayEvent(
        _ command: V2DurableWorkEventReplayCommand,
        operatorPrincipal: String,
        now: Date
    ) async throws -> V2DurableWorkEventReplayResult {
        let sourceEventID = try replayUUID(command.sourceEventID)
        guard v2PostgresTimestampCanEncode(now) else { throw V2DurableWorkReplayStoreError.corruptPersistenceState }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2DurableWorkReplayStoreError.corruptPersistenceState
            }
            let targets = try await self.batchReplayTargets(kind: command.kind, sourceEventID: sourceEventID, limit: command.limit, sql: sql)
            var requeued = 0
            var notPaused = 0
            for target in targets.prefix(command.limit) {
                let rowCommand = try V2DurableWorkReplayCommand(
                    operationID: v2BatchReplayOperationID(
                        batchOperationID: command.operationID,
                        kind: command.kind,
                        sourceEventID: sourceEventID,
                        targetUserID: target.targetUserID,
                        projectionKind: target.projectionKind
                    ),
                    target: try V2DurableWorkReplayTarget(
                        kind: command.kind,
                        sourceEventID: command.sourceEventID,
                        targetUserID: target.targetUserID.map { .init(uuid: $0) },
                        projectionKind: target.projectionKind
                    ),
                    reason: command.reason
                )
                let result = try await self.v2ReplayDurableWork(rowCommand, operatorPrincipal: operatorPrincipal, now: now, sql: sql)
                switch result.outcome {
                case .requeued: requeued += 1
                case .notPaused: notPaused += 1
                }
            }
            return .init(
                operationID: command.operationID,
                requeued: requeued,
                notPaused: notPaused,
                hasMore: targets.count > command.limit
            )
        }
    }

    /// 列出某个来源事件下仍然暂停、且可以被本批重放的目标。
    ///
    /// - Parameters:
    ///   - kind: 目标工作类型。
    ///   - sourceEventID: 来源事件标识。
    ///   - limit: 本批上限；实现会多取一行用于判断是否还有剩余。
    ///   - sql: 已处于调用方事务中的数据库句柄。
    /// - Returns: 至多 `limit + 1` 个目标，按稳定顺序排列。
    /// - Throws: 标识非法或查询失败时抛出。
    private func batchReplayTargets(
        kind: V2DurableWorkReplayTargetKind,
        sourceEventID: UUID,
        limit: Int,
        sql: any SQLDatabase
    ) async throws -> [V2DurableWorkReplayBatchTarget] {
        switch kind {
        case .userStateEvent:
            return try await sql.raw("""
                SELECT user_id AS target_user_id, projection_kind
                FROM im_v2.user_state_event_outbox
                WHERE source_event_id = \(bind: sourceEventID) AND state = 'paused'
                ORDER BY user_id, projection_kind
                LIMIT \(bind: limit + 1)
                """).all(decoding: DurableWorkReplayBatchTargetRow.self).map(\.target)
        case .contentReview:
            return try await batchReplaySingleRow(table: "content_review_jobs", keyColumn: "message_id", key: sourceEventID, sql: sql)
        case .mediaScan:
            return try await batchReplaySingleRow(table: "media_scan_outbox", keyColumn: "media_id", key: sourceEventID, sql: sql)
        case .mediaPurge:
            return try await batchReplaySingleRow(table: "media_purge_outbox", keyColumn: "media_id", key: sourceEventID, sql: sql)
        case .readReceiptPreferencePropagation, .userProjection:
            throw V2DurableWorkReplayValidationError.invalidTargetShape
        }
    }

    /// 检查按事件定位的表里是否有暂停行。
    ///
    /// 这些类型的一条事件最多只有一行工作，因此"批量"退化为 0 或 1 个目标。
    private func batchReplaySingleRow(
        table: String,
        keyColumn: String,
        key: UUID,
        sql: any SQLDatabase
    ) async throws -> [V2DurableWorkReplayBatchTarget] {
        let exists = try await sql.raw("""
            SELECT EXISTS (
                SELECT 1 FROM im_v2.\(unsafeRaw: table)
                WHERE \(unsafeRaw: keyColumn) = \(bind: key) AND state = 'paused'
            ) AS value
            """).first(decoding: ReplayExistsRow.self)?.value ?? false
        return exists ? [.init(targetUserID: nil, projectionKind: nil)] : []
    }
}

private struct ReplayInsertRow: Decodable {
    let operationID: UUID
    enum CodingKeys: String, CodingKey { case operationID = "operation_id" }
}

private struct ReplayTargetRow: Decodable {
    let sourceEventID: UUID
    enum CodingKeys: String, CodingKey { case sourceEventID = "source_event_id" }
}

/// 批量重放命中的一个精确目标。
private struct V2DurableWorkReplayBatchTarget {
    let targetUserID: UUID?
    let projectionKind: String?
}

private struct DurableWorkReplayBatchTargetRow: Decodable {
    let targetUserID: UUID
    let projectionKind: String
    enum CodingKeys: String, CodingKey {
        case targetUserID = "target_user_id", projectionKind = "projection_kind"
    }

    var target: V2DurableWorkReplayBatchTarget {
        .init(targetUserID: targetUserID, projectionKind: projectionKind)
    }
}

private struct ReplayExistsRow: Decodable { let value: Bool }

/// 由批量操作标识稳定派生行级操作标识。
///
/// 这样一次批量调用里的每一行都拥有与单目标重放完全相同的审计与幂等语义：重复调用会
/// 命中同一批行级审计，而不会重复重放。派生使用 SHA-256、应用自定义 UUID 版本，且包含
/// 目标身份，因此不同目标不会碰撞。
///
/// - Parameters:
///   - batchOperationID: 批量调用的幂等操作标识。
///   - kind: 目标工作类型。
///   - sourceEventID: 来源事件标识。
///   - targetUserID: 目标用户；按事件定位的类型为空。
///   - projectionKind: 投影类型；仅用户投影重放给出。
/// - Returns: 稳定的行级操作标识。
func v2BatchReplayOperationID(
    batchOperationID: UUID,
    kind: V2DurableWorkReplayTargetKind,
    sourceEventID: UUID,
    targetUserID: UUID?,
    projectionKind: String?
) -> UUID {
    var input = Data("im-v2-durable-work-batch-replay-v1".utf8)
    var batch = batchOperationID.uuid
    withUnsafeBytes(of: &batch) { input.append(contentsOf: $0) }
    var event = sourceEventID.uuid
    withUnsafeBytes(of: &event) { input.append(contentsOf: $0) }
    input.append(contentsOf: Data(kind.rawValue.utf8))
    if let targetUserID {
        var user = targetUserID.uuid
        withUnsafeBytes(of: &user) { input.append(contentsOf: $0) }
    }
    if let projectionKind { input.append(contentsOf: Data(projectionKind.utf8)) }
    var bytes = Array(SHA256.hash(data: input).prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x80
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    ))
}

private struct DurableWorkReplayAuditRow: Decodable {
    let operationID: UUID
    let targetKind: String
    let sourceEventID: UUID
    let targetUserID: UUID?
    let projectionKind: String?
    let reasonCode: String
    let outcome: String

    enum CodingKeys: String, CodingKey {
        case operationID = "operation_id"
        case targetKind = "target_kind"
        case sourceEventID = "source_event_id"
        case targetUserID = "target_user_id"
        case projectionKind = "projection_kind"
        case reasonCode = "reason_code"
        case outcome
    }

    func matches(_ command: V2DurableWorkReplayCommand, sourceEventID: UUID, targetUserID: UUID?) -> Bool {
        operationID == command.operationID &&
        targetKind == command.target.kind.rawValue &&
        self.sourceEventID == sourceEventID &&
        self.targetUserID == targetUserID &&
        projectionKind == command.target.projectionKind &&
        reasonCode == command.reason.rawValue
    }
}

/// 把事件标识解析为 UUID。
///
/// - Parameter identifier: 来源事件标识。
/// - Returns: 对应的 UUID。
/// - Throws: 原始值不是合法 UUID 时抛出
///   ``V2DurableWorkReplayStoreError/corruptPersistenceState``。
private func replayUUID(_ identifier: EventID) throws -> UUID {
    guard let value = UUID(uuidString: identifier.rawValue) else {
        throw V2DurableWorkReplayStoreError.corruptPersistenceState
    }
    return value
}

/// 把用户标识解析为 UUID。
///
/// - Parameter identifier: 用户标识。
/// - Returns: 对应的 UUID。
/// - Throws: 原始值不是合法 UUID 时抛出
///   ``V2DurableWorkReplayStoreError/corruptPersistenceState``。
private func replayUUID(_ identifier: UserID) throws -> UUID {
    guard let value = UUID(uuidString: identifier.rawValue) else {
        throw V2DurableWorkReplayStoreError.corruptPersistenceState
    }
    return value
}

private struct ReplayContentReviewRoomRow: Decodable {
    let roomID: UUID
    enum CodingKeys: String, CodingKey { case roomID = "room_id" }
}


private struct ReplayUserEventSourceRow: Decodable {
    let sourceRoomID: UUID?
    enum CodingKeys: String, CodingKey { case sourceRoomID = "source_room_id" }
}
