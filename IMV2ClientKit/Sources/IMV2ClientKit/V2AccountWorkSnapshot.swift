import Foundation
import GRDB

/// One SQLite snapshot of reservations and unresolved execution. No identities or payloads.
public struct V2AccountWorkSnapshot: Sendable {
    public let ordinaryCount: Int
    public let ordinaryReservedBytes: Int64
    public let controlCount: Int
    public let controlReservedBytes: Int64
    public let submittingCount: Int
    public let processingCount: Int
    public let awaitingConfirmationCount: Int
    public let needsAttentionCount: Int
    /// Age since creation of the oldest unresolved original operation;
    /// this is not time since it entered an unknown state.
    public let oldestUnresolvedOriginalAge: TimeInterval?
}

extension GRDBV2LocalSyncStore {
    /// Explicitly requested diagnostic read; never scheduled on every dispatcher wake.
    public func accountWorkSnapshot(now: Date = Date()) async throws -> V2AccountWorkSnapshot {
        let timestamp = try Self.commandRetryTimestamp(now)
        return try await databasePool.read { db in
            let ordinary = try Self.operationAdmissionUsage(db: db)
            let row = try Row.fetchOne(db, sql: """
                SELECT
                    COALESCE(SUM(CASE WHEN admission_class='readReceiptControl' THEN 1 ELSE 0 END),0) control_count,
                    COALESCE(SUM(CASE WHEN admission_class='readReceiptControl' THEN payload_bytes ELSE 0 END),0) control_bytes,
                    COALESCE(SUM(CASE WHEN execution_state='submitting' THEN 1 ELSE 0 END),0) submitting,
                    COALESCE(SUM(CASE WHEN execution_state='processing' THEN 1 ELSE 0 END),0) processing,
                    COALESCE(SUM(CASE WHEN execution_state='awaitingConfirmation' THEN 1 ELSE 0 END),0) awaiting_confirmation,
                    COALESCE(SUM(CASE WHEN scheduling_state='needsAttention' THEN 1 ELSE 0 END),0) needs_attention,
                    MIN(CASE WHEN execution_state IN ('submitting','processing','awaitingConfirmation') THEN created_at END) oldest_original
                FROM v2_operation_work WHERE scheduling_state<>'finished'
                """)!
            let oldest: Double? = row["oldest_original"]
            return .init(ordinaryCount: ordinary.count, ordinaryReservedBytes: ordinary.bytes,
                controlCount: row["control_count"], controlReservedBytes: row["control_bytes"],
                submittingCount: row["submitting"], processingCount: row["processing"],
                awaitingConfirmationCount: row["awaiting_confirmation"], needsAttentionCount: row["needs_attention"],
                oldestUnresolvedOriginalAge: oldest.map { max(0, timestamp - $0) })
        }
    }
}
