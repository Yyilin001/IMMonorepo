import Fluent
import Foundation
import SQLKit

/// 单个来源库的个人事件积压；部署按物理来源库去重后聚合，避免遗漏远端队列或重复计数。
public struct PostgresV2UserStateEventMetricsSource: V2DurableWorkMetricsSource {
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

    /// 使用与领取查询一致的租约和退避边界；已投递行不进入积压或年龄统计。
    public func loadDurableWorkMetrics() async throws -> V2DurableWorkMetricsSnapshot {
        guard let sql = database as? any SQLDatabase else { throw V2DurableWorkMetricsError.sqlUnavailable }
        guard let row = try await sql.raw("""
            WITH snapshot_now AS (SELECT CURRENT_TIMESTAMP AS value)
            SELECT
                COUNT(*) FILTER (WHERE (state = 'pending' AND next_attempt_at <= snapshot_now.value)
                    OR (state = 'leased' AND lease_until <= snapshot_now.value)) AS ready,
                COUNT(*) FILTER (WHERE state = 'leased' AND lease_until > snapshot_now.value) AS leased,
                COUNT(*) FILTER (WHERE state = 'pending' AND next_attempt_at > snapshot_now.value) AS scheduled,
                COUNT(*) FILTER (WHERE state = 'paused') AS paused,
                GREATEST(0, COALESCE(EXTRACT(EPOCH FROM (MAX(snapshot_now.value) - MIN(created_at)))::bigint, 0)) AS age
            FROM \(unsafeRaw: schema).user_state_event_outbox, snapshot_now
            WHERE state IN ('pending', 'leased', 'paused')
            """).first(decoding: UserStateEventMetricsRow.self)
        else { throw V2DurableWorkMetricsError.emptyResult }
        return .init(isAvailable: true,
            readyUserStateEventRows: Int(clamping: row.ready),
            leasedUserStateEventRows: Int(clamping: row.leased),
            scheduledUserStateEventRows: Int(clamping: row.scheduled),
            pausedUserStateEventRows: Int(clamping: row.paused),
            oldestUnfinishedUserStateEventAgeSeconds: Int(clamping: row.age))
    }
}

private struct UserStateEventMetricsRow: Decodable {
    let ready: Int64
    let leased: Int64
    let scheduled: Int64
    let paused: Int64
    let age: Int64
}
