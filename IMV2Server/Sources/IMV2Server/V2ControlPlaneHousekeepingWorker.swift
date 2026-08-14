import Fluent
import Foundation
import SQLKit

public struct V2ControlPlaneHousekeepingReport: Equatable, Sendable {
    public let deletedRows: Int

    public init(deletedRows: Int) { self.deletedRows = max(0, deletedRows) }
    public var didWork: Bool { deletedRows > 0 }
}

public protocol V2ControlPlaneHousekeepingStore: Sendable {
    func purgeTerminal(now: Date, retention: TimeInterval, limit: Int) async throws -> V2ControlPlaneHousekeepingReport
}

public struct V2ControlPlaneHousekeepingWorker: Sendable {
    private let store: any V2ControlPlaneHousekeepingStore
    private let retention: TimeInterval
    private let now: @Sendable () -> Date

    public init(
        store: any V2ControlPlaneHousekeepingStore,
        retention: TimeInterval = 7 * 86_400,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(retention.isFinite && retention > 0)
        self.store = store
        self.retention = retention
        self.now = now
    }

    public func runOnce(limit: Int) async throws -> V2ControlPlaneHousekeepingReport {
        guard limit > 0 else { throw V2ControlPlaneHousekeepingError.invalidLimit }
        return try await store.purgeTerminal(now: now(), retention: retention, limit: limit)
    }
}

public enum V2ControlPlaneHousekeepingError: Error, Equatable, Sendable {
    case invalidLimit
    case corruptPersistenceState
}

/// Retains authoritative room events/messages while removing bounded batches
/// of terminal worker bookkeeping. Fan-out rows are dismantled from leaves to
/// roots so no foreign-key fence or in-progress delivery can be bypassed.
public struct PostgresV2ControlPlaneHousekeepingStore: V2ControlPlaneHousekeepingStore {
    private let database: any Database

    public init(database: any Database) { self.database = database }

    public func purgeTerminal(
        now: Date,
        retention: TimeInterval,
        limit: Int
    ) async throws -> V2ControlPlaneHousekeepingReport {
        guard limit > 0, retention.isFinite, retention > 0 else {
            throw V2ControlPlaneHousekeepingError.invalidLimit
        }
        let cutoff = now.addingTimeInterval(-retention)
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2ControlPlaneHousekeepingError.corruptPersistenceState
            }
            var count = 0
            count += try await deleteSimple(
                sql: sql, table: "media_scan_outbox", identity: "media_id",
                where: "state = 'completed' AND completed_at <= ", order: "completed_at, media_id",
                cutoff: cutoff, limit: limit
            )
            count += try await deleteSimple(
                sql: sql, table: "media_purge_outbox", identity: "media_id",
                where: "state = 'completed' AND completed_at <= ", order: "completed_at, media_id",
                cutoff: cutoff, limit: limit
            )
            count += try await deleteSimple(
                sql: sql, table: "content_review_jobs", identity: "message_id",
                where: "state IN ('completed', 'superseded') AND completed_at <= ", order: "completed_at, message_id",
                cutoff: cutoff, limit: limit
            )
            count += try await deleteSimple(
                sql: sql, table: "public_profile_update_outbox", identity: "source_event_id",
                where: "state = 'completed' AND completed_at <= ", order: "completed_at, source_event_id",
                cutoff: cutoff, limit: limit
            )
            count += try await sql.raw("""
                WITH candidates AS (
                    SELECT actor_user_id, operation_id
                    FROM im_v2.read_receipt_preference_propagation_outbox
                    WHERE state = 'completed' AND completed_at <= \(bind: cutoff)
                    ORDER BY completed_at, actor_user_id, operation_id
                    LIMIT \(bind: limit)
                    FOR UPDATE SKIP LOCKED
                )
                DELETE FROM im_v2.read_receipt_preference_propagation_outbox AS outbox
                USING candidates
                WHERE outbox.actor_user_id = candidates.actor_user_id
                  AND outbox.operation_id = candidates.operation_id
                RETURNING 1 AS value
                """).all(decoding: ControlHousekeepingDeletedRow.self).count
            count += try await deleteSimple(
                sql: sql, table: "push_wake_outbox", identity: "dispatch_id",
                where: "state IN ('sent', 'suppressed') AND created_at <= ", order: "created_at, dispatch_id",
                cutoff: cutoff, limit: limit
            )

            // A terminal plan may have a very large audience. Every statement
            // below limits rows, not plans, so even one 100k-member room is
            // dismantled across predictable maintenance passes.
            count += try await sql.raw("""
                WITH candidates AS (
                    SELECT delivery.ctid
                    FROM im_v2.fanout_deliveries AS delivery
                    JOIN im_v2.fanout_plans AS plan
                      ON plan.source_event_id = delivery.source_event_id
                    WHERE delivery.state = 'terminal' AND plan.state = 'terminal'
                      AND plan.terminal_at <= \(bind: cutoff)
                    ORDER BY plan.terminal_at, delivery.source_event_id,
                             delivery.target_user_id, delivery.projection_kind
                    LIMIT \(bind: limit)
                    FOR UPDATE OF delivery SKIP LOCKED
                )
                DELETE FROM im_v2.fanout_deliveries AS delivery
                USING candidates WHERE delivery.ctid = candidates.ctid
                RETURNING 1 AS value
                """).all(decoding: ControlHousekeepingDeletedRow.self).count

            count += try await sql.raw("""
                WITH candidates AS (
                    SELECT inbox.ctid
                    FROM im_v2.consumer_inbox AS inbox
                    JOIN im_v2.fanout_plans AS plan
                      ON plan.source_event_id = inbox.source_event_id
                    WHERE inbox.consumer_name = 'v2-fanout-delivery'
                      AND plan.state = 'terminal' AND plan.terminal_at <= \(bind: cutoff)
                    ORDER BY plan.terminal_at, inbox.source_event_id,
                             inbox.target_user_id, inbox.projection_kind
                    LIMIT \(bind: limit)
                    FOR UPDATE OF inbox SKIP LOCKED
                )
                DELETE FROM im_v2.consumer_inbox AS inbox
                USING candidates WHERE inbox.ctid = candidates.ctid
                RETURNING 1 AS value
                """).all(decoding: ControlHousekeepingDeletedRow.self).count

            count += try await sql.raw("""
                WITH candidates AS (
                    SELECT unit.ctid
                    FROM im_v2.fanout_completion_units AS unit
                    JOIN im_v2.fanout_plans AS plan
                      ON plan.source_event_id = unit.source_event_id
                    WHERE unit.state = 'released' AND plan.state = 'terminal'
                      AND plan.terminal_at <= \(bind: cutoff)
                      AND NOT EXISTS (
                          SELECT 1 FROM im_v2.fanout_deliveries AS delivery
                          WHERE delivery.source_event_id = unit.source_event_id
                            AND delivery.completion_unit_id = unit.completion_unit_id
                      )
                    ORDER BY plan.terminal_at, unit.source_event_id, unit.completion_unit_id
                    LIMIT \(bind: limit)
                    FOR UPDATE OF unit SKIP LOCKED
                )
                DELETE FROM im_v2.fanout_completion_units AS unit
                USING candidates WHERE unit.ctid = candidates.ctid
                RETURNING 1 AS value
                """).all(decoding: ControlHousekeepingDeletedRow.self).count

            count += try await sql.raw("""
                WITH candidates AS (
                    SELECT target.ctid
                    FROM im_v2.fanout_plan_targets AS target
                    JOIN im_v2.fanout_plans AS plan
                      ON plan.source_event_id = target.source_event_id
                    WHERE plan.state = 'terminal' AND plan.terminal_at <= \(bind: cutoff)
                    ORDER BY plan.terminal_at, target.source_event_id, target.target_user_id
                    LIMIT \(bind: limit)
                    FOR UPDATE OF target SKIP LOCKED
                )
                DELETE FROM im_v2.fanout_plan_targets AS target
                USING candidates WHERE target.ctid = candidates.ctid
                RETURNING 1 AS value
                """).all(decoding: ControlHousekeepingDeletedRow.self).count

            count += try await deleteSimple(
                sql: sql, table: "room_outbox", identity: "source_event_id",
                where: "state = 'terminal' AND terminal_at <= ", order: "terminal_at, source_event_id",
                cutoff: cutoff, limit: limit
            )

            count += try await sql.raw("""
                WITH candidates AS (
                    SELECT plan.ctid
                    FROM im_v2.fanout_plans AS plan
                    WHERE plan.state = 'terminal' AND plan.terminal_at <= \(bind: cutoff)
                      AND NOT EXISTS (SELECT 1 FROM im_v2.room_outbox AS outbox WHERE outbox.plan_id = plan.plan_id)
                      AND NOT EXISTS (SELECT 1 FROM im_v2.fanout_completion_units AS unit WHERE unit.source_event_id = plan.source_event_id)
                      AND NOT EXISTS (SELECT 1 FROM im_v2.fanout_deliveries AS delivery WHERE delivery.source_event_id = plan.source_event_id)
                      AND NOT EXISTS (SELECT 1 FROM im_v2.fanout_plan_targets AS target WHERE target.source_event_id = plan.source_event_id)
                    ORDER BY plan.terminal_at, plan.source_event_id
                    LIMIT \(bind: limit)
                    FOR UPDATE OF plan SKIP LOCKED
                )
                DELETE FROM im_v2.fanout_plans AS plan
                USING candidates WHERE plan.ctid = candidates.ctid
                RETURNING 1 AS value
                """).all(decoding: ControlHousekeepingDeletedRow.self).count

            return .init(deletedRows: count)
        }
    }

    private func deleteSimple(
        sql: any SQLDatabase,
        table: String,
        identity: String,
        where predicate: String,
        order: String,
        cutoff: Date,
        limit: Int
    ) async throws -> Int {
        try await sql.raw("""
            WITH candidates AS (
                SELECT \(unsafeRaw: identity)
                FROM im_v2.\(unsafeRaw: table)
                WHERE \(unsafeRaw: predicate)\(bind: cutoff)
                ORDER BY \(unsafeRaw: order)
                LIMIT \(bind: limit)
                FOR UPDATE SKIP LOCKED
            )
            DELETE FROM im_v2.\(unsafeRaw: table) AS target
            USING candidates
            WHERE target.\(unsafeRaw: identity) = candidates.\(unsafeRaw: identity)
            RETURNING 1 AS value
            """).all(decoding: ControlHousekeepingDeletedRow.self).count
    }
}

private struct ControlHousekeepingDeletedRow: Decodable { let value: Int }
