import Fluent
import Foundation
import SQLKit

/// 扇出载荷引用回填报告。
public struct V2FanoutPayloadReferenceBackfillReport: Equatable, Sendable {
    /// 本次新建立状态引用的行数。
    public let linkedRowCount: Int
    /// 本次压缩掉内联载荷的行数。
    public let compactedRowCount: Int

    /// 本轮是否产生了实际变更。
    public var didWork: Bool { linkedRowCount > 0 || compactedRowCount > 0 }
}

/// 把已接受消息的扇出正文转换为对精确不可变消息状态的引用。
///
/// 编辑、撤回、审核等增量载荷保持内联：用折叠状态替换这些增量会改变增量同步语义，
/// 因此本回填只处理消息投影类载荷。
public struct PostgresV2FanoutPayloadReferenceBackfillWorker: Sendable {
    private let database: any Database
    private let schema: String

    /// 组合数据库与 schema。
    ///
    /// - Parameters:
    ///   - database: 存放扇出共享载荷与房间事件的数据库。
    ///   - schema: 目标 schema，需符合 `^[A-Za-z_][A-Za-z0-9_]*$`。
    ///
    /// schema 名不满足格式时直接失败，避免拼接出非法 SQL 标识符。
    public init(database: any Database, schema: String = "im_v2") {
        precondition(
            schema.range(
                of: "^[A-Za-z_][A-Za-z0-9_]*$",
                options: .regularExpression
            ) != nil
        )
        self.database = database
        self.schema = schema
    }

    /// 执行一轮有界引用回填。
    ///
    /// 只处理包含内联载荷、且正文与对应不可变状态完全一致的消息类行；
    /// 候选行使用 `FOR UPDATE SKIP LOCKED` 选取，因此多个实例可安全并行。
    ///
    /// - Parameter limit: 本轮最多处理的行数。
    /// - Returns: 本轮链接与压缩的计数。
    /// - Throws: 上限非正时抛出 ``V2FanoutPayloadReferenceBackfillError/invalidLimit``；
    ///   任务已取消时抛出 `CancellationError`；连接不支持 SQL 时抛出
    ///   ``V2FanoutPayloadReferenceBackfillError/corruptPersistence``。
    public func runOnce(limit: Int = 100) async throws -> V2FanoutPayloadReferenceBackfillReport {
        guard limit > 0 else { throw V2FanoutPayloadReferenceBackfillError.invalidLimit }
        try Task.checkCancellation()
        return try await database.transaction { database in
            guard let sql = database as? any SQLDatabase else {
                throw V2FanoutPayloadReferenceBackfillError.corruptPersistence
            }
            let rows = try await sql.raw("""
                WITH candidates AS MATERIALIZED (
                    SELECT shared.ctid, state.state_id,
                           (shared.message_state_id IS NULL) AS linked,
                           (shared.payload IS NOT NULL) AS compacted
                    FROM \(unsafeRaw: table("fanout_sync_payloads")) AS shared
                    JOIN \(unsafeRaw: table("room_events")) AS event
                      ON event.event_id = shared.source_event_id
                     AND event.event_type = 'message.accepted'
                    JOIN \(unsafeRaw: table("message_projection_state_values")) AS state
                      ON state.state_event_id = event.event_id
                     AND state.variant_key = 0
                    WHERE shared.projection_kind = 'message'
                      AND (shared.message_state_id IS NULL OR shared.payload IS NOT NULL)
                      AND shared.payload IS NOT NULL
                      AND shared.payload = state.payload
                    ORDER BY shared.source_event_id
                    LIMIT \(bind: limit)
                    FOR UPDATE OF shared SKIP LOCKED
                )
                UPDATE \(unsafeRaw: table("fanout_sync_payloads")) AS shared
                SET message_state_id = candidates.state_id,
                    payload = NULL
                FROM candidates
                WHERE shared.ctid = candidates.ctid
                RETURNING candidates.linked, candidates.compacted
                """).all(decoding: FanoutPayloadBackfillMutationRow.self)
            return .init(
                linkedRowCount: rows.lazy.filter(\.linked).count,
                compactedRowCount: rows.lazy.filter(\.compacted).count
            )
        }
    }

    /// 拼接 schema 限定的表名。
    ///
    /// - Parameter name: 表名，仅允许来自代码内常量。
    /// - Returns: 形如 `schema.table` 的限定名。
    private func table(_ name: String) -> String { "\(schema).\(name)" }
}

/// 扇出载荷引用回填错误。
public enum V2FanoutPayloadReferenceBackfillError: Error, Equatable, Sendable {
    /// 单轮处理上限为非正值。
    case invalidLimit
    /// 持久化状态损坏或数据库适配器不受支持。
    case corruptPersistence
}

private struct FanoutPayloadBackfillMutationRow: Decodable {
    let linked: Bool
    let compacted: Bool
}
