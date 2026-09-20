import Fluent
import Foundation
import SQLKit

/// 回收已关闭的应用层 MVCC 版本，同时不破坏仍按固定基准序号读取的快照产物。
///
/// 已发布的快照产物是自包含的，因此只有仍在构建中的产物需要保留历史版本。
public struct PostgresV2ProjectionVersionGCWorker: Sendable {
    private let database: any Database
    private let schema: String

    /// 组合数据库与 schema。
    ///
    /// - Parameters:
    ///   - database: 存放投影版本与检查点的数据库。
    ///   - schema: 目标 schema，需符合 `^[A-Za-z_][A-Za-z0-9_]*$`。
    ///
    /// schema 名不满足格式时直接失败，避免拼接出非法的 SQL 标识符。
    public init(database: any Database, schema: String = "im_v2") {
        precondition(schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil)
        self.database = database
        self.schema = schema
    }

    /// 执行一轮有界版本回收。
    ///
    /// 存在以该版本区间为基准序号的活动快照产物时，对应版本会被跳过；
    /// 候选行使用 `FOR UPDATE SKIP LOCKED` 选取，因此多个实例可安全并行。
    ///
    /// - Parameters:
    ///   - now: 本次判定的服务端时刻。
    ///   - limit: 本轮最多回收的版本数。
    /// - Returns: 实际回收的版本数。
    /// - Throws: 上限非正时抛出 ``V2ProjectionVersionGCError/invalidLimit``；
    ///   任务已取消时抛出 `CancellationError`；时刻不可编码或连接不支持 SQL 时抛出
    ///   ``V2ProjectionVersionGCError/corruptPersistence``。
    @discardableResult
    public func runOnce(now: Date = Date(), limit: Int = 500) async throws -> Int {
        guard limit > 0 else { throw V2ProjectionVersionGCError.invalidLimit }
        try Task.checkCancellation()
        guard v2PostgresTimestampCanEncode(now) else { throw V2ProjectionVersionGCError.corruptPersistence }
        guard let sql = database as? any SQLDatabase else {
            throw V2ProjectionVersionGCError.corruptPersistence
        }
        return try await sql.raw("""
            WITH candidates AS (
                SELECT version.ctid
                FROM \(unsafeRaw: table("user_projection_versions")) AS version
                WHERE version.valid_to_sequence IS NOT NULL
                  AND NOT EXISTS (
                      SELECT 1
                      FROM \(unsafeRaw: table("sync_snapshot_artifacts")) AS artifact
                      WHERE artifact.user_id = version.user_id
                        AND artifact.state = 'building'
                        AND artifact.expires_at > \(bind: now)
                        AND artifact.base_user_sync_sequence >= version.valid_from_sequence
                        AND artifact.base_user_sync_sequence < version.valid_to_sequence
                  )
                ORDER BY version.valid_to_sequence, version.user_id,
                         version.projection_kind, version.entity_key
                LIMIT \(bind: limit)
                FOR UPDATE SKIP LOCKED
            )
            DELETE FROM \(unsafeRaw: table("user_projection_versions")) AS version
            USING candidates
            WHERE version.ctid = candidates.ctid
            RETURNING 1 AS value
            """).all(decoding: ProjectionVersionGCDeletedRow.self).count
    }

    /// 拼接 schema 限定的表名。
    ///
    /// - Parameter name: 表名，仅允许来自代码内常量。
    /// - Returns: 形如 `schema.table` 的限定名。
    private func table(_ name: String) -> String { "\(schema).\(name)" }
}

/// 投影版本回收错误。
public enum V2ProjectionVersionGCError: Error, Equatable, Sendable {
    /// 单轮回收上限为非正值。
    case invalidLimit
    /// 持久化状态损坏或数据库适配器不受支持。
    case corruptPersistence
}

private struct ProjectionVersionGCDeletedRow: Decodable { let value: Int }
