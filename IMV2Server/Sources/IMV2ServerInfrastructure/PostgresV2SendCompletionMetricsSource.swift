import FluentKit
import Foundation
import IMV2ServerContracts
import SQLKit

/// One source per physical room-owner database, including the control database.
/// Reads catalog estimates and relation sizes only; never counts or reads message rows.
public struct PostgresV2SendCompletionMetricsSource: V2DurableWorkMetricsSource {
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
            SELECT relation.reltuples::bigint AS estimated_rows,
                   pg_relation_size(relation.oid)::bigint AS heap_bytes,
                   pg_indexes_size(relation.oid)::bigint AS index_bytes,
                   pg_total_relation_size(relation.oid)::bigint AS total_bytes
            FROM pg_catalog.pg_class AS relation
            JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid=relation.relnamespace
            WHERE namespace.nspname=\(bind: schema) AND relation.relname='message_send_completions'
              AND relation.relkind='r'
            """).first(decoding: SendCompletionMetricsRow.self),
              row.heapBytes >= 0, row.indexBytes >= 0, row.totalBytes >= 0 else {
            // An absent or newly partitioned table needs an explicit collector change.
            // Do not publish an empty-success snapshot for an unmeasured owner.
            throw V2DurableWorkMetricsError.emptyResult
        }
        return .init(isAvailable: true, sendCompletionStorage: .init(
            estimatedRows: row.estimatedRows < 0 ? nil : Int(clamping: row.estimatedRows),
            heapBytes: Int(clamping: row.heapBytes), indexBytes: Int(clamping: row.indexBytes),
            totalBytes: Int(clamping: row.totalBytes)))
    }
}

private struct SendCompletionMetricsRow: Decodable {
    let estimatedRows: Int64
    let heapBytes: Int64
    let indexBytes: Int64
    let totalBytes: Int64
    enum CodingKeys: String, CodingKey {
        case estimatedRows = "estimated_rows", heapBytes = "heap_bytes", indexBytes = "index_bytes", totalBytes = "total_bytes"
    }
}
