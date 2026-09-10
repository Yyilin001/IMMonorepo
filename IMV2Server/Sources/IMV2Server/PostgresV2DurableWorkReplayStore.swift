import Fluent
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
        let sourceEventID = try replayUUID(command.target.sourceEventID)
        let targetUserID = try command.target.targetUserID.map(replayUUID)
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2DurableWorkReplayStoreError.corruptPersistenceState
            }

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
            case .roomOutbox:
                didRequeue = try await sql.raw("""
                    UPDATE im_v2.room_outbox
                    SET state = 'pending', claim_token = NULL, lease_expires_at = NULL,
                        next_attempt_at = NULL, paused_at = NULL, last_failure_code = NULL,
                        retry_count = 0
                    WHERE source_event_id = \(bind: sourceEventID)
                      AND state = 'paused'
                    RETURNING source_event_id
                    """).first(decoding: ReplayTargetRow.self) != nil
            case .fanoutDelivery:
                guard let targetUserID, let projectionKind = command.target.projectionKind else {
                    throw V2DurableWorkReplayStoreError.corruptPersistenceState
                }
                didRequeue = try await sql.raw("""
                    UPDATE im_v2.fanout_deliveries
                    SET state = 'pending', claim_token = NULL, lease_expires_at = NULL,
                        next_attempt_at = NULL, paused_at = NULL, last_failure_code = NULL,
                        retry_count = 0
                    WHERE source_event_id = \(bind: sourceEventID)
                      AND target_user_id = \(bind: targetUserID)
                      AND projection_kind = \(bind: projectionKind)
                      AND state = 'paused'
                    RETURNING source_event_id
                    """).first(decoding: ReplayTargetRow.self) != nil
            case .contentReview:
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
}

private struct ReplayInsertRow: Decodable {
    let operationID: UUID
    enum CodingKeys: String, CodingKey { case operationID = "operation_id" }
}

private struct ReplayTargetRow: Decodable {
    let sourceEventID: UUID
    enum CodingKeys: String, CodingKey { case sourceEventID = "source_event_id" }
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
