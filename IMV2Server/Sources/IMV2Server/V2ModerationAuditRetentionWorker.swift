import Fluent
import Foundation
import SQLKit

/// Audit retention is deliberately narrower than business-data retention.
/// It removes only expired audit copies; moderation operations, events, and
/// idempotency results remain available for their own retention policies.
public protocol V2ModerationAuditRetentionStore: Sendable {
    func deleteExpiredAuditEntries(now: Date, limit: Int) async throws -> Int
}

/// Caller-scheduled bounded maintenance. Multiple workers can run safely:
/// PostgreSQL locks each selected audit row and skips rows another worker has
/// already claimed for deletion.
public struct V2ModerationAuditRetentionWorker: Sendable {
    private let store: any V2ModerationAuditRetentionStore
    private let now: @Sendable () -> Date

    public init(store: any V2ModerationAuditRetentionStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    @discardableResult
    public func runOnce(limit: Int) async throws -> Int {
        precondition(limit > 0)
        return try await store.deleteExpiredAuditEntries(now: now(), limit: limit)
    }
}

public struct PostgresV2ModerationAuditRetentionStore: V2ModerationAuditRetentionStore {
    private let database: any Database

    public init(database: any Database) { self.database = database }

    public func deleteExpiredAuditEntries(now: Date, limit: Int) async throws -> Int {
        guard limit > 0 else { throw V2ModerationStoreError.corruptPersistenceState }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2ModerationStoreError.corruptPersistenceState }
            guard let row = try await sql.raw("""
                WITH selected AS (
                    SELECT actor_user_id, operation_id
                    FROM im_v2.moderation_audit_entries
                    WHERE retain_until <= \(bind: now)
                    ORDER BY retain_until, actor_user_id, operation_id
                    LIMIT \(bind: limit)
                    FOR UPDATE SKIP LOCKED
                ), deleted AS (
                    DELETE FROM im_v2.moderation_audit_entries AS audit
                    USING selected
                    WHERE audit.actor_user_id = selected.actor_user_id
                      AND audit.operation_id = selected.operation_id
                    RETURNING 1
                )
                SELECT COUNT(*)::bigint AS value FROM deleted
                """).first(decoding: ModerationRetentionCountRow.self) else {
                throw V2ModerationStoreError.corruptPersistenceState
            }
            guard row.value >= 0, row.value <= Int64(limit) else { throw V2ModerationStoreError.corruptPersistenceState }
            return Int(row.value)
        }
    }
}

private struct ModerationRetentionCountRow: Decodable { let value: Int64 }
