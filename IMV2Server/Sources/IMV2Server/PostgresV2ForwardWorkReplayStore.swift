import Fluent
import Foundation
import SQLKit

/// 转发工作重放的持久化实现。
///
/// 审计记录与「暂停转为待处理」的状态跃迁共用归属侧同一事务；
/// 重放保留原有导出、目标标识、已复制的摘要与扫描要求，不会重新生成这些内容。
public struct PostgresV2ForwardWorkReplayStore: V2ForwardWorkReplayStore {
    private let database: any Database
    /// 组合数据库。
    ///
    /// - Parameter database: 存放转发导出、收件箱与重放审计的数据库。
    public init(database: any Database) { self.database = database }

    /// 重放一条暂停的转发工作。
    ///
    /// 同一操作标识已存在审计记录时返回其原有结论并标记为幂等；否则先以唯一约束抢占该操作标识，
    /// 再按工作类型校验归属并把对应任务恢复为待处理，最后回填审计结论。
    ///
    /// - Parameters:
    ///   - command: 已校验的重放请求。
    ///   - operatorPrincipal: 已认证的运维主体标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 重放结果。
    /// - Throws: 运维主体非法时抛出 ``V2ForwardWorkReplayError/invalidTarget``；
    ///   请求分片与导出归属不符时抛出 ``V2ForwardWorkReplayError/ownerChanged``；
    ///   目标缺失、媒体序号越界或收件箱仍处于待处理时抛出
    ///   ``V2ForwardWorkReplayError/targetUnavailable``；时刻不可编码或连接不支持 SQL 时抛出
    ///   ``V2ForwardWorkReplayError/corruptPersistenceState``。
    public func replay(_ command: V2ForwardWorkReplayCommand, operatorPrincipal: String, now: Date) async throws -> V2DurableWorkReplayResult {
        guard V2DurableWorkOperatorReplayService.isValidPrincipal(operatorPrincipal) else { throw V2ForwardWorkReplayError.invalidTarget }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2ForwardWorkReplayError.corruptPersistenceState }
            func priorResult() async throws -> V2DurableWorkReplayResult? {
                guard let prior = try await sql.raw("""
                    SELECT shard_id, target_kind, export_id, ordinal, reason_code, outcome
                    FROM im_v2.forward_work_replay_audit WHERE operation_id = \(bind: command.operationID) FOR UPDATE
                    """).first(decoding: ReplayForwardAudit.self) else { return nil }
                guard prior.shardID == command.shardID, prior.kind == command.kind.rawValue,
                      prior.exportID == command.exportID, prior.ordinal == command.ordinal, prior.reason == command.reason.rawValue,
                      let outcome = V2DurableWorkReplayOutcome(rawValue: prior.outcome)
                else { throw V2ForwardWorkReplayError.idempotencyConflict }
                return .init(operationID: command.operationID, outcome: outcome, wasIdempotent: true)
            }
            if let prior = try await priorResult() { return prior }
            guard v2PostgresTimestampCanEncode(now) else { throw V2ForwardWorkReplayError.corruptPersistenceState }

            let inserted = try await sql.raw("""
                INSERT INTO im_v2.forward_work_replay_audit
                    (operation_id, operator_principal, shard_id, target_kind, export_id, ordinal, reason_code, requested_at, outcome)
                VALUES (\(bind: command.operationID), \(bind: operatorPrincipal), \(bind: command.shardID),
                    \(bind: command.kind.rawValue), \(bind: command.exportID), \(bind: command.ordinal),
                    \(bind: command.reason.rawValue), \(bind: now), 'processing')
                ON CONFLICT (operation_id) DO NOTHING RETURNING true AS value
                """).first(decoding: ReplayForwardBool.self) != nil
            if !inserted {
                guard let prior = try await priorResult() else { throw V2ForwardWorkReplayError.corruptPersistenceState }
                return prior
            }

            let changed: Bool
            switch command.kind {
            case .delivery:
                guard let owner = try await sql.raw("""
                    SELECT source_room_id AS room_id, source_shard_id AS shard_id, source_epoch AS epoch
                    FROM im_v2.message_forward_exports WHERE export_id = \(bind: command.exportID)
                    """).first(decoding: ReplayForwardOwner.self) else { throw V2ForwardWorkReplayError.targetUnavailable }
                try await assertOwner(owner, command: command, sql: sql)
                changed = try await sql.raw("""
                    UPDATE im_v2.message_forward_delivery_jobs
                    SET state = 'pending', claim_token = NULL, lease_expires_at = NULL,
                        next_attempt_at = \(bind: now), retry_count = 0
                    WHERE export_id = \(bind: command.exportID) AND state = 'paused'
                    RETURNING true AS value
                    """).first(decoding: ReplayForwardBool.self) != nil
            case .media:
                // Match import locking: inbox -> room -> import job.
                guard let inbox = try await sql.raw("""
                    SELECT export_id, payload, payload_digest, state, result_message_id, result_room_sequence, error_code
                    FROM im_v2.message_forward_inbox WHERE export_id = \(bind: command.exportID) FOR UPDATE
                    """).first(decoding: ForwardInboxRow.self) else { throw V2ForwardWorkReplayError.targetUnavailable }
                let export = try inbox.export
                guard let ordinal = command.ordinal, export.intent.media.indices.contains(ordinal)
                else { throw V2ForwardWorkReplayError.targetUnavailable }
                try await assertOwner(.init(roomID: export.intent.targetRoomID, shardID: export.intent.targetShardID,
                    epoch: export.intent.targetEpoch), command: command, sql: sql)
                if inbox.state == "pending" {
                    changed = try await sql.raw("""
                        UPDATE im_v2.message_forward_media_imports
                        SET state = 'pending', claim_token = NULL, lease_expires_at = NULL,
                            next_attempt_at = \(bind: now), retry_count = 0
                        WHERE export_id = \(bind: command.exportID) AND ordinal = \(bind: ordinal) AND state = 'paused'
                        RETURNING true AS value
                        """).first(decoding: ReplayForwardBool.self) != nil
                } else { changed = false }
            }
            let outcome: V2DurableWorkReplayOutcome = changed ? .requeued : .notPaused
            try await sql.raw("""
                UPDATE im_v2.forward_work_replay_audit SET outcome = \(bind: outcome.rawValue)
                WHERE operation_id = \(bind: command.operationID) AND outcome = 'processing'
                """).run()
            return .init(operationID: command.operationID, outcome: outcome, wasIdempotent: false)
        }
    }

    /// 校验命令指定的分片与房间当前归属一致。
    ///
    /// 房间行会被加锁，以确保校验结果在本次事务内保持有效。
    ///
    /// - Parameters:
    ///   - owner: 导出记录携带的归属。
    ///   - command: 重放请求。
    ///   - sql: 当前事务使用的数据库连接。
    /// - Throws: 分片不符或房间当前归属与记录不一致时抛出
    ///   ``V2ForwardWorkReplayError/ownerChanged``。
    private func assertOwner(_ owner: ReplayForwardOwner, command: V2ForwardWorkReplayCommand, sql: any SQLDatabase) async throws {
        guard owner.shardID == command.shardID else { throw V2ForwardWorkReplayError.ownerChanged }
        guard let current = try await sql.raw("""
            SELECT room_id, room_shard_id AS shard_id, owner_epoch AS epoch
            FROM im_v2.rooms WHERE room_id = \(bind: owner.roomID) FOR UPDATE
            """).first(decoding: ReplayForwardOwner.self),
              current.shardID == owner.shardID, current.epoch == owner.epoch
        else { throw V2ForwardWorkReplayError.ownerChanged }
    }
}

private struct ReplayForwardBool: Decodable { let value: Bool }
private struct ReplayForwardOwner: Decodable {
    let roomID: UUID; let shardID: String; let epoch: Int64
    enum CodingKeys: String, CodingKey { case roomID = "room_id", shardID = "shard_id", epoch }
}
private struct ReplayForwardAudit: Decodable {
    let shardID: String; let kind: String; let exportID: UUID; let ordinal: Int?; let reason: String; let outcome: String
    enum CodingKeys: String, CodingKey {
        case shardID = "shard_id", kind = "target_kind", exportID = "export_id", ordinal, reason = "reason_code", outcome
    }
}
