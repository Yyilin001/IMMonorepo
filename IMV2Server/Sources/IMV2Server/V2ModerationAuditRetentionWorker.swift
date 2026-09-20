import Fluent
import Foundation
import SQLKit

/// 审核审计留存能力，其作用范围刻意窄于业务数据留存。
///
/// 这里只删除已过期的审计副本；审核操作、事件与幂等结果仍按各自的留存策略保留。
public protocol V2ModerationAuditRetentionStore: Sendable {
    /// 删除已过期的审计条目。
    ///
    /// - Parameters:
    ///   - now: 本次判定的服务端时刻。
    ///   - limit: 本次最多删除的条数。
    /// - Returns: 实际删除的条数。
    /// - Throws: 参数非法或持久化失败时抛出。
    func deleteExpiredAuditEntries(now: Date, limit: Int) async throws -> Int
}

/// 由调用方调度的有界维护工作器。
///
/// 可安全并行运行多个实例：PostgreSQL 会锁定选中的审计行，并跳过已被其他实例认领的行。
public struct V2ModerationAuditRetentionWorker: Sendable {
    private let store: any V2ModerationAuditRetentionStore
    private let now: @Sendable () -> Date

    /// 组合审计留存存储与授时来源。
    ///
    /// - Parameters:
    ///   - store: 实际执行删除的存储实现。
    ///   - now: 可注入的当前时刻读取函数。
    public init(store: any V2ModerationAuditRetentionStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    /// 执行一轮有界审计清理。
    ///
    /// - Parameter limit: 本轮最多删除的条数，需大于零。
    /// - Returns: 实际删除的条数。
    /// - Throws: `limit` 非正时抛出
    ///   ``V2ModerationStoreError/corruptPersistenceState``；其余错误来自存储实现。
    @discardableResult
    public func runOnce(limit: Int) async throws -> Int {
        guard limit > 0 else { throw V2ModerationStoreError.corruptPersistenceState }
        return try await store.deleteExpiredAuditEntries(now: now(), limit: limit)
    }
}

/// 基于 PostgreSQL 的审核审计留存实现。
public struct PostgresV2ModerationAuditRetentionStore: V2ModerationAuditRetentionStore {
    private let database: any Database

    /// 组合数据库。
    ///
    /// - Parameter database: 存放审核审计条目的数据库。
    public init(database: any Database) { self.database = database }

    /// 在单个事务内按留存期限删除一批审计条目。
    ///
    /// 选择阶段使用 `FOR UPDATE SKIP LOCKED` 取得有界批次，删除数量与请求上限不符时
    /// 视为持久化状态异常，避免统计口径失真。
    ///
    /// - Parameters:
    ///   - now: 本次判定的服务端时刻。
    ///   - limit: 本轮最多删除的条数，需大于零。
    /// - Returns: 实际删除的条数。
    /// - Throws: 参数非法、事务连接不支持 SQL 或结果不可解码时抛出
    ///   ``V2ModerationStoreError/corruptPersistenceState``。
    public func deleteExpiredAuditEntries(now: Date, limit: Int) async throws -> Int {
        guard limit > 0, v2PostgresTimestampCanEncode(now) else { throw V2ModerationStoreError.corruptPersistenceState }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2ModerationStoreError.corruptPersistenceState }
            guard let row = try await sql.raw("""
                WITH selected AS (
                    SELECT actor_user_id, operation_id
                    FROM im_v2.moderation_audit_entries AS audit
                    WHERE retain_until <= \(bind: now)
                      AND (SELECT true FROM im_v2.rooms AS room
                           WHERE room.room_id = audit.room_id
                           FOR SHARE OF room SKIP LOCKED)
                    ORDER BY retain_until, actor_user_id, operation_id
                    LIMIT \(bind: limit)
                    FOR UPDATE OF audit SKIP LOCKED
                ), deleted AS (
                    DELETE FROM im_v2.moderation_audit_entries AS audit
                    USING selected
                    WHERE audit.actor_user_id = selected.actor_user_id
                      AND audit.operation_id = selected.operation_id
                    RETURNING 1
                )
                SELECT COUNT(*)::bigint AS value FROM deleted
                """).first(decoding: ModerationRetentionCountRow.self) else {
                throw V2ModerationStoreError.corruptPersistenceState
            }
            guard row.value >= 0, row.value <= Int64(limit) else { throw V2ModerationStoreError.corruptPersistenceState }
            return Int(row.value)
        }
    }
}

private struct ModerationRetentionCountRow: Decodable { let value: Int64 }
