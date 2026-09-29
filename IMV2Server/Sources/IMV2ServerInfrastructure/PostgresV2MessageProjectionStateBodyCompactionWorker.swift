import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import SQLKit

/// 消息投影状态正文压缩报告。
public struct V2MessageProjectionStateBodyCompactionReport: Equatable, Sendable {
    /// 本次压缩的状态数量。
    public let compactedCount: Int

    /// 保存压缩计数。
    ///
    /// - Parameter compactedCount: 压缩数量，需非负。
    ///
    /// 计数为负时直接失败，避免错误统计进入运行路径。
    public init(compactedCount: Int) {
        precondition(compactedCount >= 0)
        self.compactedCount = compactedCount
    }

    /// 本轮是否产生了实际变更。
    public var didWork: Bool { compactedCount > 0 }
}

/// 回收消息投影状态中重复保存的规范正文。
///
/// 仅当不可变来源房间事件与状态处于同一物理 schema 时，才会清空已接受修订为 1 的状态正文；
/// 独立的用户分片通常不含该房间事件，因此会保留其唯一必需的内联副本。
/// 等值与身份谓词保证压缩只是物理表示变化：逻辑状态身份、投影授权与传输载荷都保持不变。
public struct PostgresV2MessageProjectionStateBodyCompactionWorker: Sendable {
    private let database: any Database
    private let schema: String

    /// 组合数据库与 schema。
    ///
    /// - Parameters:
    ///   - database: 存放投影状态与房间事件的数据库。
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

    /// 执行一轮有界正文压缩。
    ///
    /// 只有正文与来源房间事件完全一致、且状态未撤回、修订为 1、变体键为 0、
    /// 来源事件与状态事件相同的行才会被压缩；候选行使用 `FOR UPDATE SKIP LOCKED` 选取。
    ///
    /// - Parameter limit: 本轮最多压缩的状态数，需大于零。
    /// - Returns: 本轮压缩报告。
    /// - Throws: 任务已取消时抛出 `CancellationError`；连接不支持 SQL 时抛出
    ///   ``V2MessageProjectionStatePersistenceError/corruptPersistence``。
    public func runOnce(limit: Int = 100) async throws
        -> V2MessageProjectionStateBodyCompactionReport
    {
        precondition(limit > 0)
        try Task.checkCancellation()
        return try await database.transaction { database in
            guard let sql = database as? any SQLDatabase else {
                throw V2MessageProjectionStatePersistenceError.corruptPersistence
            }
            let rows = try await sql.raw("""
                WITH candidates AS MATERIALIZED (
                    SELECT state.state_id
                    FROM \(unsafeRaw: table("message_projection_states")) AS state
                    JOIN \(unsafeRaw: table("room_events")) AS event
                      ON event.event_id = state.state_event_id
                     AND event.room_id = state.room_id
                     AND event.event_type = 'message.accepted'
                     AND lower(event.payload->>'message_id') = state.message_id::text
                     AND lower(event.payload->>'room_id') = state.room_id::text
                     AND (event.payload->>'message_revision')::bigint =
                           state.message_revision
                     AND event.payload = state.payload
                    WHERE state.payload_storage = 'inline'
                      AND state.message_revision = 1
                      AND state.variant_key = 0
                      AND state.origin_event_id = state.state_event_id
                      AND NOT state.is_withdrawn
                    ORDER BY state.state_event_id, state.state_id
                    LIMIT \(bind: limit)
                    FOR UPDATE OF state SKIP LOCKED
                )
                UPDATE \(unsafeRaw: table("message_projection_states")) AS state
                SET payload = NULL,
                    payload_storage = 'room_event'
                FROM candidates
                WHERE state.state_id = candidates.state_id
                  AND state.payload_storage = 'inline'
                RETURNING state.state_id
                """).all(decoding: CompactedStateRow.self)
            return .init(compactedCount: rows.count)
        }
    }

    /// 拼接 schema 限定的表名。
    ///
    /// - Parameter name: 表名，仅允许来自代码内常量。
    /// - Returns: 形如 `schema.table` 的限定名。
    private func table(_ name: String) -> String { "\(schema).\(name)" }
}

private struct CompactedStateRow: Decodable {
    let stateID: UUID

    private enum CodingKeys: String, CodingKey {
        case stateID = "state_id"
    }
}
