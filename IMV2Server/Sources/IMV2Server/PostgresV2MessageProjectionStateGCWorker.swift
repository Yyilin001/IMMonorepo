import FluentKit
import Foundation
import SQLKit

/// 清理消息投影状态的回收工作器。
///
/// 只删除超过安全宽限期、不是控制存储当前生效修订的
/// 不可变状态；候选行使用行锁，多个回收实例不会重复认领。
public struct PostgresV2MessageProjectionStateGCWorker: Sendable {
    private let database: any Database
    private let schema: String
    private let retention: TimeInterval

    /// 组合数据库、schema 与保留宽限期。
    ///
    /// - Parameters:
    ///   - database: 存放投影状态与相关引用的数据库。
    ///   - schema: 目标 schema，需符合 `^[A-Za-z_][A-Za-z0-9_]*$`。
    ///   - retention: 状态创建后需保留的秒数，需为正的有限值。
    ///
    /// schema 名或保留期不满足约束时直接失败，避免运行期出现越界回收。
    public init(
        database: any Database,
        schema: String = "im_v2",
        retention: TimeInterval
    ) {
        precondition(
            schema.range(
                of: "^[A-Za-z_][A-Za-z0-9_]*$",
                options: .regularExpression
            ) != nil
        )
        precondition(retention.isFinite && retention > 0)
        self.database = database
        self.schema = schema
        self.retention = retention
    }

    /// 执行一轮有界状态回收。
    ///
    /// 该状态仍是未撤回消息的当前内容修订时，
    /// 对应状态会被跳过；候选行使用 `FOR UPDATE SKIP LOCKED` 选取，多实例可并行。
    ///
    /// - Parameters:
    ///   - now: 本次判定的服务端时刻。
    ///   - limit: 本轮最多回收的状态数。
    /// - Returns: 实际回收的状态数。
    /// - Throws: 上限非正时抛出 ``V2MessageProjectionStateGCError/invalidLimit``；
    ///   任务已取消时抛出 `CancellationError`；保留截止点不可编码或连接不支持 SQL 时抛出
    ///   ``V2MessageProjectionStateGCError/corruptPersistence``。
    @discardableResult
    public func runOnce(now: Date = Date(), limit: Int = 500) async throws -> Int {
        guard limit > 0 else { throw V2MessageProjectionStateGCError.invalidLimit }
        try Task.checkCancellation()
        guard let cutoff = v2PostgresPastTimestamp(now: now, interval: retention) else {
            throw V2MessageProjectionStateGCError.corruptPersistence
        }
        guard let sql = database as? any SQLDatabase else {
            throw V2MessageProjectionStateGCError.corruptPersistence
        }
        return try await sql.raw("""
            WITH candidates AS (
                SELECT state.state_id
                FROM \(unsafeRaw: table("message_projection_states")) AS state
                WHERE state.created_at < \(bind: cutoff)
                  AND NOT EXISTS (
                      SELECT 1
                      FROM \(unsafeRaw: table("messages")) AS message
                      WHERE message.message_id = state.message_id
                        AND message.content_revision = state.message_revision
                        AND message.withdrawn_at IS NULL
                  )
                ORDER BY state.created_at, state.state_id
                LIMIT \(bind: limit)
                FOR UPDATE OF state SKIP LOCKED
            )
            DELETE FROM \(unsafeRaw: table("message_projection_states")) AS state
            USING candidates
            WHERE state.state_id = candidates.state_id
            RETURNING 1 AS value
            """).all(decoding: MessageProjectionStateGCDeletedRow.self).count
    }

    /// 拼接 schema 限定的表名。
    ///
    /// - Parameter name: 表名，仅允许来自代码内常量。
    /// - Returns: 形如 `schema.table` 的限定名。
    private func table(_ name: String) -> String { "\(schema).\(name)" }
}

/// 消息投影状态回收错误。
public enum V2MessageProjectionStateGCError: Error, Equatable, Sendable {
    /// 单轮回收上限为非正值。
    case invalidLimit
    /// 持久化状态损坏或数据库适配器不受支持。
    case corruptPersistence
}

private struct MessageProjectionStateGCDeletedRow: Decodable { let value: Int }
