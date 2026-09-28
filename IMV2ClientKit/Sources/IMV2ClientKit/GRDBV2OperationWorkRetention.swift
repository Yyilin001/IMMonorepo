import Foundation
import GRDB

extension GRDBV2LocalSyncStore {
    /// Removes only locally completed history whose domain state is independently
    /// retained. Unknown/rejected/conflicted work and protected source files are
    /// never aged out. Accepted sends also wait for local display convergence.
    /// Server original receipts are unaffected.
    @discardableResult
    public func pruneCompletedOperationHistory(now: Date, limit: Int = 32) throws -> Int {
        guard (1...128).contains(limit) else { throw V2OperationWorkError.invalidRecord }
        let cutoff = try Self.commandRetryTimestamp(now.addingTimeInterval(-7 * 24 * 60 * 60))
        return try databasePool.write { db in
            let ids = try String.fetchAll(db, sql: """
                SELECT w.work_id FROM v2_operation_work w
                WHERE w.execution_state='committed' AND w.scheduling_state='finished'
                  AND w.completed_at<=?
                  AND NOT EXISTS(SELECT 1 FROM v2_operation_dependencies d WHERE d.parent_work_id=w.work_id)
                  AND (
                    (w.operation_kind='profileUpdate' AND EXISTS(
                      SELECT 1 FROM v2_profile_intents p WHERE p.work_id=w.work_id AND p.source_released=1
                        AND EXISTS(SELECT 1 FROM v2_profile_intents newer
                          JOIN v2_operation_work completed ON completed.work_id=newer.work_id
                          WHERE newer.account_id=p.account_id AND newer.local_sequence>p.local_sequence
                            AND completed.execution_state='committed')))
                    OR (w.operation_kind IN ('conversationPreference','messageFavorite') AND EXISTS(
                      SELECT 1 FROM v2_personal_preference_intents p WHERE p.work_id=w.work_id))
                    OR (w.operation_kind IN ('contactAlias','groupNickname') AND EXISTS(
                      SELECT 1 FROM v2_name_operations p WHERE p.work_id=w.work_id
                        AND EXISTS(SELECT 1 FROM v2_operation_work newer
                          WHERE newer.ordering_key=w.ordering_key AND newer.local_sequence>w.local_sequence
                            AND newer.operation_kind=w.operation_kind AND newer.execution_state='committed')))
                    OR (w.operation_kind='readReceipt' AND EXISTS(
                      SELECT 1 FROM v2_read_receipt_operations p WHERE p.work_id=w.work_id))
                    OR (w.operation_kind IN ('editMessage','withdrawMessage') AND EXISTS(
                      SELECT 1 FROM v2_message_mutation_operations p WHERE p.work_id=w.work_id))
                    OR (w.operation_kind='reaction' AND EXISTS(
                      SELECT 1 FROM v2_message_reaction_intents p WHERE p.work_id=w.work_id))
                    OR (w.operation_kind='forwardMessage' AND EXISTS(
                      SELECT 1 FROM v2_forward_plan_operations p WHERE p.work_id=w.work_id))
                    OR (w.operation_kind IN ('memberMute','moderatedMemberRemoval') AND EXISTS(
                      SELECT 1 FROM v2_member_administration_intents p WHERE p.work_id=w.work_id))
                    OR (w.operation_kind IN ('relationship','userBlock') AND EXISTS(
                      SELECT 1 FROM v2_social_operations p WHERE p.work_id=w.work_id))
                    OR (w.operation_kind IN ('strangerMessagePreference','userAddPreference','readReceiptPreference','liveActivityPreference') AND EXISTS(
                      SELECT 1 FROM v2_account_preference_operations p WHERE p.work_id=w.work_id))
                    OR (w.operation_kind IN ('groupInvite','groupJoinRequest','groupJoinDecision') AND EXISTS(
                      SELECT 1 FROM v2_invitation_operation_intents p WHERE p.work_id=w.work_id
                        AND p.secret_reference IS NULL AND p.secret_release_pending=0))
                    OR (w.operation_kind='moderation' AND EXISTS(
                      SELECT 1 FROM v2_message_moderation_operations p WHERE p.work_id=w.work_id))
                    OR (w.operation_kind='directRoom' AND EXISTS(
                      SELECT 1 FROM v2_direct_room_operations p WHERE p.work_id=w.work_id))
                    OR (w.operation_kind='groupRoom' AND EXISTS(
                      SELECT 1 FROM v2_group_creation_operations p WHERE p.work_id=w.work_id))
                    OR (w.operation_kind='membership' AND EXISTS(
                      SELECT 1 FROM v2_membership_intents p WHERE p.work_id=w.work_id))
                    OR (w.operation_kind IN ('pinnedMessage','groupAnnouncement','groupPermission','groupRole') AND EXISTS(
                      SELECT 1 FROM v2_group_capability_intents p WHERE p.work_id=w.work_id))
                    OR (w.operation_kind='sendMessage' AND EXISTS(
                      SELECT 1 FROM v2_message_send_operations m
                      JOIN v2_send_intents p ON p.work_id=m.work_id
                      WHERE m.work_id=w.work_id AND p.stage='handedOff'
                        AND m.accepted_projection_observed=1
                        AND NOT EXISTS(SELECT 1 FROM v2_send_intent_dependencies d
                          JOIN v2_resource_transfer_jobs j ON j.job_id=d.job_id
                          WHERE d.intent_id=p.intent_id AND (j.stage<>'ready' OR j.staging_released<>1
                            OR EXISTS(SELECT 1 FROM v2_background_transfer_tasks b
                              WHERE b.job_id=j.job_id AND b.state='active')))
                        AND NOT EXISTS(SELECT 1 FROM v2_send_intent_import_dependencies d
                          JOIN v2_resource_import_jobs j ON j.job_id=d.job_id
                          WHERE d.intent_id=p.intent_id AND j.stage<>'ready')
                        AND NOT EXISTS(SELECT 1 FROM v2_send_intents child WHERE child.replacement_of=p.intent_id)))
                  )
                ORDER BY w.completed_at,w.local_sequence LIMIT ?
                """, arguments: [cutoff, limit])
            for id in ids {
                // Remove outgoing edges only after this child has completed.
                // Incoming edges pin parents until their dependents are removed.
                try db.execute(sql: "DELETE FROM v2_operation_dependencies WHERE child_work_id=?", arguments: [id])
                try db.execute(sql: "DELETE FROM v2_profile_intents WHERE work_id=? AND source_released=1", arguments: [id])
                try db.execute(sql: "DELETE FROM v2_personal_preference_intents WHERE work_id=?", arguments: [id])
                try db.execute(sql: "DELETE FROM v2_name_operations WHERE work_id=?", arguments: [id])
                try db.execute(sql: "DELETE FROM v2_read_receipt_operations WHERE work_id=?", arguments: [id])
                try db.execute(sql: "DELETE FROM v2_message_mutation_operations WHERE work_id=?", arguments: [id])
                try db.execute(sql: "DELETE FROM v2_message_reaction_intents WHERE work_id=?", arguments: [id])
                try db.execute(sql: "DELETE FROM v2_forward_plan_operations WHERE work_id=?", arguments: [id])
                try db.execute(sql: "DELETE FROM v2_member_administration_intents WHERE work_id=?", arguments: [id])
                try db.execute(sql: "DELETE FROM v2_group_capability_intents WHERE work_id=?", arguments: [id])
                try db.execute(sql: "DELETE FROM v2_membership_intents WHERE work_id=?", arguments: [id])
                try db.execute(sql: "DELETE FROM v2_group_creation_operations WHERE work_id=?", arguments: [id])
                try db.execute(sql: "DELETE FROM v2_direct_room_operations WHERE work_id=?", arguments: [id])
                try db.execute(sql: "DELETE FROM v2_message_moderation_operations WHERE work_id=?", arguments: [id])
                try db.execute(sql: "DELETE FROM v2_invitation_operation_intents WHERE work_id=? AND secret_reference IS NULL AND secret_release_pending=0", arguments: [id])
                try db.execute(sql: "DELETE FROM v2_social_operation_proposals WHERE work_id=?", arguments: [id])
                try db.execute(sql: "DELETE FROM v2_social_operations WHERE work_id=?", arguments: [id])
                try db.execute(sql: "DELETE FROM v2_account_preference_intents WHERE work_id=?", arguments: [id])
                try db.execute(sql: "DELETE FROM v2_account_preference_operations WHERE work_id=?", arguments: [id])
                // Resource owners have already released protected upload sources.
                // Keep independent jobs and background tombstones for their own GC.
                try db.execute(sql: "DELETE FROM v2_send_intent_dependencies WHERE intent_id IN (SELECT intent_id FROM v2_send_intents WHERE work_id=?)", arguments: [id])
                try db.execute(sql: "DELETE FROM v2_send_intent_import_dependencies WHERE intent_id IN (SELECT intent_id FROM v2_send_intents WHERE work_id=?)", arguments: [id])
                try db.execute(sql: "DELETE FROM v2_send_intents WHERE work_id=?", arguments: [id])
                try db.execute(sql: "DELETE FROM v2_message_send_operations WHERE work_id=?", arguments: [id])
                try db.execute(sql: "DELETE FROM v2_operation_work WHERE work_id=?", arguments: [id])
            }
            return ids.count
        }
    }
}
