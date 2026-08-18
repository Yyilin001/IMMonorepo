import Fluent
import Foundation
import IMV2Core
import SQLKit

public struct V2ControlPlaneHousekeepingReport: Equatable, Sendable {
    public let deletedRows: Int
    public let purgedIdempotencyRows: Int
    public let purgedExpiredCredentialReplayRows: Int
    public let purgedExpiredConnectionLeaseRows: Int

    public init(
        deletedRows: Int,
        purgedIdempotencyRows: Int = 0,
        purgedExpiredCredentialReplayRows: Int = 0,
        purgedExpiredConnectionLeaseRows: Int = 0
    ) {
        self.deletedRows = max(0, deletedRows)
        self.purgedIdempotencyRows = max(0, purgedIdempotencyRows)
        self.purgedExpiredCredentialReplayRows = max(0, purgedExpiredCredentialReplayRows)
        self.purgedExpiredConnectionLeaseRows = max(0, purgedExpiredConnectionLeaseRows)
    }
    public var didWork: Bool { deletedRows > 0 }
}

public protocol V2ControlPlaneHousekeepingStore: Sendable {
    func purgeTerminal(
        now: Date,
        retention: TimeInterval,
        idempotencyRetention: TimeInterval,
        limit: Int
    ) async throws -> V2ControlPlaneHousekeepingReport
}

public struct V2ControlPlaneHousekeepingWorker: Sendable {
    private let store: any V2ControlPlaneHousekeepingStore
    private let retention: TimeInterval
    private let idempotencyRetention: TimeInterval
    private let now: @Sendable () -> Date

    public init(
        store: any V2ControlPlaneHousekeepingStore,
        retention: TimeInterval = 7 * 86_400,
        idempotencyRetention: TimeInterval = V2IdempotencyPolicy.minimumServerRetention,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(retention.isFinite && retention > 0)
        precondition(
            idempotencyRetention.isFinite &&
                idempotencyRetention >= V2IdempotencyPolicy.minimumServerRetention
        )
        self.store = store
        self.retention = retention
        self.idempotencyRetention = idempotencyRetention
        self.now = now
    }

    public func runOnce(limit: Int) async throws -> V2ControlPlaneHousekeepingReport {
        guard limit > 0 else { throw V2ControlPlaneHousekeepingError.invalidLimit }
        return try await store.purgeTerminal(
            now: now(),
            retention: retention,
            idempotencyRetention: idempotencyRetention,
            limit: limit
        )
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
        idempotencyRetention: TimeInterval,
        limit: Int
    ) async throws -> V2ControlPlaneHousekeepingReport {
        guard limit > 0, retention.isFinite, retention > 0,
              idempotencyRetention.isFinite,
              idempotencyRetention >= V2IdempotencyPolicy.minimumServerRetention
        else {
            throw V2ControlPlaneHousekeepingError.invalidLimit
        }
        let cutoff = now.addingTimeInterval(-retention)
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2ControlPlaneHousekeepingError.corruptPersistenceState
            }
            // `limit` is a transaction-wide row budget, not a per-table
            // multiplier. Divide it fairly across every cleanup class so a
            // single pass has predictable lock/WAL cost and, when the budget
            // covers all categories, cold tables do not starve behind a
            // continuously busy fan-out table.
            var budget = ControlHousekeepingDeletionBudget(
                total: limit,
                categoryCount: 15
            )
            var count = 0
            count += try await deleteSimple(
                sql: sql, table: "media_scan_outbox", identity: "media_id",
                where: "state = 'completed' AND completed_at <= ", order: "completed_at, media_id",
                cutoff: cutoff, limit: budget.take()
            )
            count += try await deleteSimple(
                sql: sql, table: "media_purge_outbox", identity: "media_id",
                where: "state = 'completed' AND completed_at <= ", order: "completed_at, media_id",
                cutoff: cutoff, limit: budget.take()
            )
            count += try await deleteSimple(
                sql: sql, table: "content_review_jobs", identity: "message_id",
                where: "state IN ('completed', 'superseded') AND completed_at <= ", order: "completed_at, message_id",
                cutoff: cutoff, limit: budget.take()
            )
            count += try await deleteSimple(
                sql: sql, table: "public_profile_update_outbox", identity: "source_event_id",
                where: "state = 'completed' AND completed_at <= ", order: "completed_at, source_event_id",
                cutoff: cutoff, limit: budget.take()
            )
            let readReceiptPropagationLimit = budget.take()
            count += try await sql.raw("""
                WITH candidates AS (
                    SELECT actor_user_id, operation_id
                    FROM im_v2.read_receipt_preference_propagation_outbox
                    WHERE state = 'completed' AND completed_at <= \(bind: cutoff)
                    ORDER BY completed_at, actor_user_id, operation_id
                    LIMIT \(bind: readReceiptPropagationLimit)
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
                cutoff: cutoff, limit: budget.take()
            )

            // A terminal plan may have a very large audience. Every statement
            // below limits rows, not plans, so even one 100k-member room is
            // dismantled across predictable maintenance passes.
            let deliveryLimit = budget.take()
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
                    LIMIT \(bind: deliveryLimit)
                    FOR UPDATE OF delivery SKIP LOCKED
                )
                DELETE FROM im_v2.fanout_deliveries AS delivery
                USING candidates WHERE delivery.ctid = candidates.ctid
                RETURNING 1 AS value
                """).all(decoding: ControlHousekeepingDeletedRow.self).count

            let inboxLimit = budget.take()
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
                    LIMIT \(bind: inboxLimit)
                    FOR UPDATE OF inbox SKIP LOCKED
                )
                DELETE FROM im_v2.consumer_inbox AS inbox
                USING candidates WHERE inbox.ctid = candidates.ctid
                RETURNING 1 AS value
                """).all(decoding: ControlHousekeepingDeletedRow.self).count

            let completionUnitLimit = budget.take()
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
                    LIMIT \(bind: completionUnitLimit)
                    FOR UPDATE OF unit SKIP LOCKED
                )
                DELETE FROM im_v2.fanout_completion_units AS unit
                USING candidates WHERE unit.ctid = candidates.ctid
                RETURNING 1 AS value
                """).all(decoding: ControlHousekeepingDeletedRow.self).count

            let planTargetLimit = budget.take()
            count += try await sql.raw("""
                WITH candidates AS (
                    SELECT target.ctid
                    FROM im_v2.fanout_plan_targets AS target
                    JOIN im_v2.fanout_plans AS plan
                      ON plan.source_event_id = target.source_event_id
                    WHERE plan.state = 'terminal' AND plan.terminal_at <= \(bind: cutoff)
                    ORDER BY plan.terminal_at, target.source_event_id, target.target_user_id
                    LIMIT \(bind: planTargetLimit)
                    FOR UPDATE OF target SKIP LOCKED
                )
                DELETE FROM im_v2.fanout_plan_targets AS target
                USING candidates WHERE target.ctid = candidates.ctid
                RETURNING 1 AS value
                """).all(decoding: ControlHousekeepingDeletedRow.self).count

            count += try await deleteSimple(
                sql: sql, table: "room_outbox", identity: "source_event_id",
                where: "state = 'terminal' AND terminal_at <= ", order: "terminal_at, source_event_id",
                cutoff: cutoff, limit: budget.take()
            )

            let planLimit = budget.take()
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
                    LIMIT \(bind: planLimit)
                    FOR UPDATE OF plan SKIP LOCKED
                )
                DELETE FROM im_v2.fanout_plans AS plan
                USING candidates WHERE plan.ctid = candidates.ctid
                RETURNING 1 AS value
                """).all(decoding: ControlHousekeepingDeletedRow.self).count

            // Authentication replay rows contain encrypted bearer material;
            // their own replay expiry is the deletion boundary, independent
            // of the longer command-idempotency window.
            let credentialReplays = try await deleteSimple(
                sql: sql, table: "device_credential_operations", identity: "ctid",
                where: "replay_expires_at <= ", order: "replay_expires_at, ctid",
                cutoff: now, limit: budget.take()
            )
            let connectionLeases = try await deleteSimple(
                sql: sql, table: "user_live_presence_leases", identity: "connection_id",
                where: "expires_at <= ", order: "expires_at, connection_id",
                cutoff: now, limit: budget.take()
            )
            let idempotencyRows = try await purgeIdempotencyResults(
                sql: sql,
                cutoff: now.addingTimeInterval(-idempotencyRetention),
                rotationSeed: now,
                limit: budget.take()
            )
            count += credentialReplays + connectionLeases + idempotencyRows
            return .init(
                deletedRows: count,
                purgedIdempotencyRows: idempotencyRows,
                purgedExpiredCredentialReplayRows: credentialReplays,
                purgedExpiredConnectionLeaseRows: connectionLeases
            )
        }
    }

    /// Ordinary user-command ledgers are replay results, not authoritative
    /// domain history. Select a rotating subset when the configured batch is
    /// smaller than the table count, and divide the batch across that subset;
    /// one maintenance pass therefore cannot amplify `limit` by table count.
    private func purgeIdempotencyResults(
        sql: any SQLDatabase,
        cutoff: Date,
        rotationSeed: Date,
        limit: Int
    ) async throws -> Int {
        let tables = Self.idempotencyTables
        let selectedCount = min(limit, tables.count)
        guard selectedCount > 0 else { return 0 }
        let start = abs(Int(rotationSeed.timeIntervalSince1970 / 60)) % tables.count
        let perTableLimit = max(1, limit / selectedCount)
        var deleted = 0
        for offset in 0 ..< selectedCount {
            let descriptor = tables[(start + offset) % tables.count]
            deleted += try await sql.raw("""
                WITH candidates AS (
                    SELECT target.ctid
                    FROM im_v2.\(unsafeRaw: descriptor.table) AS target
                    WHERE target.\(unsafeRaw: descriptor.timestamp) <= \(bind: cutoff)
                      \(unsafeRaw: descriptor.additionalPredicate)
                    ORDER BY target.\(unsafeRaw: descriptor.timestamp), target.ctid
                    LIMIT \(bind: perTableLimit)
                    FOR UPDATE OF target SKIP LOCKED
                )
                DELETE FROM im_v2.\(unsafeRaw: descriptor.table) AS target
                USING candidates
                WHERE target.ctid = candidates.ctid
                RETURNING 1 AS value
                """).all(decoding: ControlHousekeepingDeletedRow.self).count
        }
        return deleted
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

    private struct IdempotencyTable: Sendable {
        let table: String
        let timestamp: String
        let additionalPredicate: String
    }

    private static let idempotencyTables: [IdempotencyTable] = [
        .init(table: "direct_room_operations", timestamp: "created_at", additionalPredicate: ""),
        .init(table: "user_relationship_operations", timestamp: "updated_at", additionalPredicate: ""),
        .init(table: "user_block_operations", timestamp: "updated_at", additionalPredicate: ""),
        .init(table: "stranger_message_preference_operations", timestamp: "updated_at", additionalPredicate: ""),
        .init(table: "room_membership_operations", timestamp: "created_at", additionalPredicate: ""),
        .init(table: "media_upload_operations", timestamp: "created_at", additionalPredicate: ""),
        .init(table: "message_withdrawal_operations", timestamp: "created_at", additionalPredicate: ""),
        .init(table: "moderation_operations", timestamp: "created_at", additionalPredicate: "AND NOT EXISTS (SELECT 1 FROM im_v2.moderation_audit_entries AS audit WHERE audit.actor_user_id = target.actor_user_id AND audit.operation_id = target.operation_id)"),
        .init(table: "message_edit_operations", timestamp: "created_at", additionalPredicate: ""),
        .init(table: "read_receipt_operations", timestamp: "recorded_at", additionalPredicate: ""),
        .init(table: "message_reaction_operations", timestamp: "created_at", additionalPredicate: ""),
        .init(table: "group_room_operations", timestamp: "created_at", additionalPredicate: ""),
        .init(table: "public_profile_update_operations", timestamp: "created_at", additionalPredicate: ""),
        .init(table: "user_add_preference_operations", timestamp: "updated_at", additionalPredicate: ""),
        .init(table: "read_receipt_preference_operations", timestamp: "updated_at", additionalPredicate: "AND NOT EXISTS (SELECT 1 FROM im_v2.read_receipt_preference_propagation_outbox AS outbox WHERE outbox.actor_user_id = target.actor_user_id AND outbox.operation_id = target.operation_id)"),
        .init(table: "user_live_activity_preference_operations", timestamp: "updated_at", additionalPredicate: ""),
        .init(table: "user_room_preference_operations", timestamp: "updated_at", additionalPredicate: ""),
        .init(table: "user_message_favorite_operations", timestamp: "updated_at", additionalPredicate: ""),
        .init(table: "room_pinned_message_operations", timestamp: "created_at", additionalPredicate: ""),
        .init(table: "group_announcement_operations", timestamp: "created_at", additionalPredicate: ""),
        .init(table: "group_permission_operations", timestamp: "created_at", additionalPredicate: ""),
        .init(table: "group_role_operations", timestamp: "created_at", additionalPredicate: ""),
        .init(table: "message_forward_operations", timestamp: "created_at", additionalPredicate: ""),
        .init(table: "device_session_operations", timestamp: "created_at", additionalPredicate: ""),
        .init(table: "special_account_message_operations", timestamp: "created_at", additionalPredicate: ""),
        .init(table: "user_contact_alias_operations", timestamp: "created_at", additionalPredicate: ""),
        .init(table: "room_member_nickname_operations", timestamp: "created_at", additionalPredicate: "")
    ]
}

private struct ControlHousekeepingDeletedRow: Decodable { let value: Int }

private struct ControlHousekeepingDeletionBudget {
    private var remaining: Int
    private var remainingCategoryCount: Int

    init(total: Int, categoryCount: Int) {
        precondition(total > 0 && categoryCount > 0)
        remaining = total
        remainingCategoryCount = categoryCount
    }

    mutating func take() -> Int {
        guard remaining > 0 else {
            remainingCategoryCount = max(0, remainingCategoryCount - 1)
            return 0
        }
        let allocation = max(1, remaining / max(1, remainingCategoryCount))
        remaining -= allocation
        remainingCategoryCount = max(0, remainingCategoryCount - 1)
        return allocation
    }
}
