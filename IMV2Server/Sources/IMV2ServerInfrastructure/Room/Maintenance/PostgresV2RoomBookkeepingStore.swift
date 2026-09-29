import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit

/// 清理终态房间任务和操作。控制工作器排除这些表，
/// 因此每项删除都只有一个物理所有者。
public struct PostgresV2RoomBookkeepingStore: Sendable {
    private let database: any Database
    private let timeouts: V2RoomActivationSQLTimeouts

    public init(database: any Database, timeouts: V2RoomActivationSQLTimeouts = .default) {
        self.database = database
        self.timeouts = timeouts
    }

    public func purge(token: V2RoomActivationToken, now: Date,
                      retention: TimeInterval, idempotencyRetention: TimeInterval,
                      rowLimit: Int) async throws -> V2ActorRoomBookkeepingPurgeResultWire {
        let tables = PostgresV2ControlPlaneHousekeepingStore.idempotencyTables.filter(\.roomOwned)
        let categoryCount = tables.count + 1
        guard categoryCount <= rowLimit, rowLimit <= 10_000,
              retention.isFinite, retention > 0,
              idempotencyRetention.isFinite,
              idempotencyRetention >= V2IdempotencyPolicy.minimumServerRetention,
              let cutoff = v2PostgresPastTimestamp(now: now, interval: retention),
              let idempotencyCutoff = v2PostgresPastTimestamp(now: now, interval: idempotencyRetention),
              let roomID = token.roomID.uuidValue else {
            throw V2ControlPlaneHousekeepingError.invalidLimit
        }
        let attempt = V2RoomTransactionAttempt()
        do {
            return try await v2WithRoomScopedTransaction(database: database, timeouts: timeouts) { transaction in
                try await attempt.body {
                    guard let sql = transaction as? any SQLDatabase else {
                        throw V2ControlPlaneHousekeepingError.corruptPersistenceState
                    }
                    try await v2RequireRoomActivations(tokens: [token], sql: sql, timeouts: timeouts)
                    var budget = ControlHousekeepingDeletionBudget(total: rowLimit,
                        categoryCount: categoryCount, rotation: 0)
                    let reviewLimit = budget.take()
                    let reviews = try await sql.raw("""
                        WITH candidates AS (
                            SELECT job.ctid FROM im_v2.content_review_jobs AS job
                            WHERE job.room_id = \(bind: roomID)
                              AND job.state IN ('completed', 'superseded')
                              AND job.completed_at <= \(bind: cutoff)
                            ORDER BY job.completed_at, job.message_id
                            LIMIT \(bind: reviewLimit)
                            FOR UPDATE OF job SKIP LOCKED
                        )
                        DELETE FROM im_v2.content_review_jobs AS job
                        USING candidates WHERE job.ctid = candidates.ctid
                        RETURNING 1 AS value
                        """).all(decoding: RoomHousekeepingDeletedRow.self).count
                    var operations = 0
                    for descriptor in tables {
                        let limit = budget.take()
                        operations += try await sql.raw("""
                            WITH candidates AS (
                                SELECT target.ctid
                                FROM im_v2.\(unsafeRaw: descriptor.table) AS target
                                WHERE target.room_id = \(bind: roomID)
                                  AND target.\(unsafeRaw: descriptor.timestamp) <= \(bind: idempotencyCutoff)
                                  \(unsafeRaw: descriptor.additionalPredicate)
                                ORDER BY target.\(unsafeRaw: descriptor.timestamp), target.ctid
                                LIMIT \(bind: limit)
                                FOR UPDATE OF target SKIP LOCKED
                            )
                            DELETE FROM im_v2.\(unsafeRaw: descriptor.table) AS target
                            USING candidates WHERE target.ctid = candidates.ctid
                            RETURNING 1 AS value
                            """).all(decoding: RoomHousekeepingDeletedRow.self).count
                    }
                    return .init(deletedReviewJobs: reviews, deletedOperationRows: operations)
                }
            }
        } catch { throw error }
    }
}

private struct RoomHousekeepingDeletedRow: Decodable { let value: Int }
