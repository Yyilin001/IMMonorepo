import Foundation
import GRDB

/// 运行时能够处理的持久化命令通道。
///
/// 调度时只选择实际安装了处理器的通道，避免不受支持的到期记录使其他运行时持续刷新。
/// 会话能力包含会话状态与消息收藏；转发按计划分块调度。
public enum V2DurableCommandLane: Sendable, CaseIterable, Hashable {
    case messages, withdrawals, redactions, edits, reactions, readReceipts
    case membership, memberMutes, moderatedMemberRemovals, groupCapabilities
    case conversationCapabilities, social, groupCreation, forwardPlans
}

extension GRDBV2LocalSyncStore {
    /// 为指定命令通道创建最早重试时间查询与数据库观察。
    ///
    /// - Parameter lanes: 当前运行时实际支持的通道；空集合产生无到期时间的查询。
    /// - Returns: 复用本地数据库池的调度来源，日期以 Unix 秒数读取。查询和观察错误由返回的闭包或流传播。
    ///
    /// 观察会合并重复的最早时间，通知仅表示需要重读；它不保证每条命令变化都有独立事件。
    /// 流终止会请求取消观察任务。返回值持有数据库池，使用方应在存储关闭前停止相关调度。
    public nonisolated func commandRetrySchedule(lanes: Set<V2DurableCommandLane>) -> V2CommandRetrySchedule {
        let query = Self.commandRetryScheduleQuery(lanes: lanes)
        let pool = databasePool
        return .init(
            nextAttemptAt: {
                try await pool.read { db in
                    try Double.fetchOne(db, sql: query).map(Date.init(timeIntervalSince1970:))
                }
            },
            updates: {
                AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
                    let task = Task {
                        do {
                            let observation = ValueObservation.tracking { db in
                                try Double.fetchOne(db, sql: query)
                            }.removeDuplicates()
                            for try await _ in observation.values(in: pool, bufferingPolicy: .bufferingNewest(1)) {
                                continuation.yield(())
                            }
                            continuation.finish()
                        } catch { continuation.finish(throwing: error) }
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            }
        )
    }

    /// 生成选定通道的最早重试时间查询，不读取命令载荷。
    ///
    /// - Parameter lanes: 从固定枚举选择的通道；表名和状态值均来自实现内的固定映射。
    /// - Returns: 返回单个最早 Unix 秒数或 `NULL` 的 SQL；没有通道时为 `SELECT NULL`。
    ///
    /// 按枚举声明顺序组合查询，使观察范围和查询顺序稳定。一般通道只查询 pending 状态；
    /// 建群额外包含 finalizing 和 cancelling。活跃转发计划缺少下一分块时使用零时间使其立即进入处理。
    static func commandRetryScheduleQuery(lanes: Set<V2DurableCommandLane>) -> String {
        var candidates: [String] = []
        func pending(_ table: String, states: String = "'pending'") {
            let predicate = states == "'pending'" ? "state = 'pending'" : "state IN (\(states))"
            candidates.append("SELECT MIN(next_attempt_at) AS due FROM \(table) WHERE \(predicate)")
        }
        // Fixed ordering makes both observation regions and query plans stable.
        for lane in V2DurableCommandLane.allCases where lanes.contains(lane) {
            switch lane {
            case .messages:
                pending("v2_pending_message_commands")
                pending("v2_message_operation_recoveries")
            case .withdrawals: pending("v2_pending_message_withdrawals")
            case .redactions: pending("v2_pending_message_redactions")
            case .edits: pending("v2_pending_message_edits")
            case .reactions: pending("v2_pending_message_reactions")
            case .readReceipts: pending("v2_pending_read_receipts")
            case .membership: pending("v2_pending_membership_commands")
            case .memberMutes: pending("v2_pending_member_mutes")
            case .moderatedMemberRemovals: pending("v2_pending_moderated_member_removals")
            case .groupCapabilities: pending("v2_pending_group_capabilities")
            case .conversationCapabilities:
                pending("v2_pending_conversation_states")
                pending("v2_pending_message_favorites")
            case .social: pending("v2_pending_social_commands")
            case .groupCreation: pending("v2_pending_group_room_creations", states: "'pending','finalizing','cancelling'")
            case .forwardPlans:
                pending("v2_forward_message_chunks")
                candidates.append("""
                    SELECT 0.0 AS due FROM v2_forward_message_plans AS plan
                    WHERE plan.state = 'active' AND NOT EXISTS (
                        SELECT 1 FROM v2_forward_message_chunks AS chunk
                        WHERE chunk.plan_id = plan.plan_id AND chunk.chunk_index = plan.next_chunk_index
                    ) LIMIT 1
                    """)
            }
        }
        guard !candidates.isEmpty else { return "SELECT NULL" }
        // Each subquery reads an indexed minimum, never command payloads.
        return "SELECT MIN(due) FROM (" + candidates.map { "SELECT due FROM (\($0))" }.joined(separator: " UNION ALL ") + ")"
    }
}
