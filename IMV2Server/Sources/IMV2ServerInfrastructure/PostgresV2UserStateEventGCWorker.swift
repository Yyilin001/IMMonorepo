import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import SQLKit

/// 有界回收来源库的已确认个人事件；目标端收据继续承担压缩后的重放去重。
public struct PostgresV2UserStateEventGCWorker: Sendable {
    private let database: any Database
    private let schema: String
    private let retention: TimeInterval

    public init(database: any Database, schema: String = "im_v2", retention: TimeInterval = 7 * 86_400) {
        precondition(schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil)
        precondition(retention.isFinite && retention > 0)
        self.database = database
        self.schema = schema
        self.retention = retention
    }

    /// 从确认完成时间计算保留期；待投递、已领取和暂停事件始终保留。
    @discardableResult
    public func runOnce(now: Date = Date(), limit: Int = 500) async throws -> Int {
        guard limit > 0 else { throw V2UserStateEventGCError.invalidLimit }
        try Task.checkCancellation()
        guard let cutoff = v2PostgresPastTimestamp(now: now, interval: retention),
              let sql = database as? any SQLDatabase else { throw V2UserStateEventGCError.corruptPersistence }
        return try await sql.raw("""
            WITH candidates AS (
                SELECT source_event_id, user_id, projection_kind
                FROM \(unsafeRaw: schema).user_state_event_outbox AS work
                WHERE state = 'delivered' AND delivered_at < \(bind: cutoff)
                  AND (work.source_room_id IS NULL OR (
                      SELECT true FROM \(unsafeRaw: schema).rooms AS room
                      WHERE room.room_id = work.source_room_id
                      FOR SHARE OF room SKIP LOCKED
                  ))
                ORDER BY delivered_at, source_event_id, user_id, projection_kind
                LIMIT \(bind: min(limit, 1024))
                FOR UPDATE OF work SKIP LOCKED
            )
            DELETE FROM \(unsafeRaw: schema).user_state_event_outbox AS work
            USING candidates
            WHERE work.source_event_id = candidates.source_event_id
              AND work.user_id = candidates.user_id
              AND work.projection_kind = candidates.projection_kind
            RETURNING 1 AS value
            """).all(decoding: UserStateEventGCDeletedRow.self).count
    }
}

public enum V2UserStateEventGCError: Error, Equatable, Sendable {
    case invalidLimit
    case corruptPersistence
}

private struct UserStateEventGCDeletedRow: Decodable { let value: Int }
