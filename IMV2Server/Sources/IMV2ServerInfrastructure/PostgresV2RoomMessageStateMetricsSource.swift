import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import SQLKit

/// 房间来源库的消息状态容量；与用户分片指标分开采集，避免同库部署重复计数。
public struct PostgresV2RoomMessageStateMetricsSource: V2DurableWorkMetricsSource {
    private let database: any Database
    private let schema: String

    public init(database: any Database, schema: String = "im_v2") {
        precondition(schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil)
        self.database = database
        self.schema = schema
    }

    public func durableWorkMetricsSnapshot() async -> V2DurableWorkMetricsSnapshot {
        do { return try await loadDurableWorkMetrics() }
        catch { return .unavailable }
    }

    public func loadDurableWorkMetrics() async throws -> V2DurableWorkMetricsSnapshot {
        guard let sql = database as? any SQLDatabase else { throw V2DurableWorkMetricsError.sqlUnavailable }
        guard let row = try await sql.raw("""
            SELECT
                COALESCE((SELECT n_live_tup::bigint FROM pg_stat_user_tables
                    WHERE schemaname = \(bind: schema) AND relname = 'message_projection_states'), 0) AS estimated_rows,
                pg_total_relation_size(\(bind: "\(schema).message_projection_states")::regclass)::bigint AS relation_bytes,
                COALESCE((SELECT relation.reltuples::bigint FROM pg_class AS relation
                    JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
                    WHERE namespace.nspname = \(bind: schema)
                      AND relation.relname = 'message_projection_states_inline_accepted_idx'), 0) AS inline_rows
            """).first(decoding: RoomMessageStateMetricsRow.self)
        else { throw V2DurableWorkMetricsError.emptyResult }
        return .init(isAvailable: true,
            messageProjectionStatesEstimatedRows: max(0, Int(clamping: row.estimatedRows)),
            messageProjectionStatesRelationBytes: max(0, Int(clamping: row.relationBytes)),
            messageProjectionStateInlineBodyEstimatedRows: max(0, Int(clamping: row.inlineRows)))
    }
}

private struct RoomMessageStateMetricsRow: Decodable {
    let estimatedRows: Int64
    let relationBytes: Int64
    let inlineRows: Int64
    enum CodingKeys: String, CodingKey {
        case estimatedRows = "estimated_rows", relationBytes = "relation_bytes", inlineRows = "inline_rows"
    }
}
