import Foundation
import GRDB
import IMV2Core

extension GRDBV2LocalSyncStore {
    // Only an explicit membership revocation is proof of departure. An absent
    // room projection during startup or snapshot replacement is not proof.
    static let departedGroupAvatarPredicate = """
        EXISTS (SELECT 1 FROM v2_room_membership_states m WHERE m.room_id=g.room_id AND m.is_member=0)
        """
    static let groupAvatarCleanupPredicate = """
        (\(departedGroupAvatarPredicate)) AND (
            (submission_started=0 AND stage IN ('preparing','needsAttention'))
            OR (stage='closed' AND closed_disposition='awaitingDecision')
            OR (stage IN ('submitted','needsAttention') AND submission_started=1
                AND (recovery_action IS NULL OR recovery_action<>'closeIfAbsent')))
        """

    /// Account recovery owns uncertain outcomes. Exhausting submission retries
    /// switches to receipt-or-closure recovery; it never creates a new command.
    /// Repeated recovery failures wait a minute and respect server cooldowns.
    func reconcileGroupAvatarRecovery(now: Date) throws {
        let time = try Self.commandRetryTimestamp(now)
        try databasePool.write { db in
            let ids = try String.fetchAll(db, sql: """
                SELECT operation_id FROM v2_group_avatar_intents g
                WHERE (claim_until IS NULL OR claim_until<=?) AND (
                    (\(Self.groupAvatarCleanupPredicate)) OR
                    (submission_started=1 AND (stage='needsAttention' OR (stage='submitted' AND attempts>=5))
                        AND MAX(retry_at,server_retry_not_before)<=?))
                ORDER BY retry_at,created_at,operation_id LIMIT 32
                """, arguments: [time, time])
            for raw in ids {
                let value = try Self.requireGroupAvatarIntent(.init(raw), db: db)
                if !value.submissionStarted || value.stage == .closed {
                    if value.stage == .closed {
                        try db.execute(sql: "UPDATE v2_group_avatar_intents SET closed_disposition='abandoned' WHERE operation_id=?", arguments: [raw])
                    } else {
                        try db.execute(sql: "UPDATE v2_group_avatar_intents SET stage='cancelled',issue=NULL WHERE operation_id=?", arguments: [raw])
                    }
                    if let job = value.uploadJobID { try Self.requestUnboundAvatarUploadCancellation(job, db: db) }
                    if let job = value.importJobID { try Self.requestUnboundAvatarImportCancellation(job, db: db) }
                } else {
                    let next = value.recoveryAction == .closeIfAbsent ? now.addingTimeInterval(60) : now
                    try db.execute(sql: """
                        UPDATE v2_group_avatar_intents SET stage='submitted',recovery_action='closeIfAbsent',
                            attempts=0,retry_at=MAX(?,retry_at,server_retry_not_before),issue=NULL,claim_id=NULL,claim_until=NULL
                        WHERE operation_id=?
                        """, arguments: [try Self.commandRetryTimestamp(next), raw])
                }
            }
        }
    }
}
